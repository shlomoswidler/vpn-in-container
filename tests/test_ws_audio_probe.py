"""Tests for tests/e2e/ws_audio_probe.py, the e2e audio scenario's WebSocket client and analyzer.

The PCM and the server's WebSocket frames are built here independently of the probe's code
(RFC 6455 section 5.2 for the frames; s16le interleaved stereo for the PCM), and the probe
must tell the tone it expects from silence, other frequencies, swapped channels, noise, a
quiet tone and a stream read a byte or a sample off.
Run: python3 -m unittest discover -s tests
"""

import base64
import cmath
import hashlib
import importlib.util
import json
import math
import random
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROBE = REPO_ROOT / "tests" / "e2e" / "ws_audio_probe.py"
RATE = 44100
TONE = "tone:1000,1500"


def load_probe():
    spec = importlib.util.spec_from_file_location("ws_audio_probe", PROBE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pcm(left, right, seconds: float = 1.5) -> bytes:
    """Interleaved s16le stereo: LEFT and RIGHT are functions of time (s) in [-1, 1]."""
    frames = round(seconds * RATE)
    samples = []
    for i in range(frames):
        t = i / RATE
        samples += [max(-32768, min(32767, round(channel(t) * 32768))) for channel in (left, right)]
    return struct.pack(f"<{len(samples)}h", *samples)


def sine(hz: float, amplitude: float = 0.25):
    return lambda t: amplitude * math.sin(2 * math.pi * hz * t)


def silent(_t: float) -> float:
    return 0.0


def noise(seed: int, amplitude: float = 0.25):
    rng = random.Random(seed)
    return lambda _t: rng.uniform(-amplitude, amplitude)


def server_frame(opcode: int, payload: bytes, fin: bool = True, first_bits: int = 0) -> bytes:
    """An unmasked frame as a server sends it."""
    first = (0x80 if fin else 0) | first_bits | opcode
    if len(payload) < 126:
        head = struct.pack("!BB", first, len(payload))
    elif len(payload) < 65536:
        head = struct.pack("!BBH", first, 126, len(payload))
    else:
        head = struct.pack("!BBQ", first, 127, len(payload))
    return head + payload


def unmask_client_frame(frame: bytes) -> tuple[int, bytes]:
    """(opcode, payload) of a whole, final, masked client frame."""
    assert frame[0] & 0x80, "not final"
    assert frame[1] & 0x80, "not masked"
    length, position = frame[1] & 0x7F, 2
    if length == 126:
        (length,) = struct.unpack_from("!H", frame, 2)
        position = 4
    elif length == 127:
        (length,) = struct.unpack_from("!Q", frame, 2)
        position = 10
    mask, payload = frame[position : position + 4], frame[position + 4 :]
    assert len(payload) == length, (len(payload), length)
    return frame[0] & 0x0F, bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


class ContentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_probe()
        cls.tone = pcm(sine(1000), sine(1500))

    def problems(self, data: bytes, expect: str = TONE) -> list[str]:
        return self.probe.content_summary(data, expect)["problems"]

    def test_the_expected_tone_passes(self):
        summary = self.probe.content_summary(self.tone, TONE)
        self.assertEqual(summary["problems"], [])
        self.assertAlmostEqual(summary["peak_hz_left"], 1000, delta=10)
        self.assertAlmostEqual(summary["peak_hz_right"], 1500, delta=10)
        self.assertGreater(summary["tone_fraction_left"], 0.99)
        self.assertAlmostEqual(summary["rms_left"], 0.25 / math.sqrt(2), places=3)

    def test_the_tone_with_some_noise_passes(self):
        data = pcm(lambda t: sine(1000)(t) + noise(1, 0.02)(t), lambda t: sine(1500)(t))
        self.assertEqual(self.problems(data), [])

    def test_silence_passes_as_silence_and_fails_as_a_tone(self):
        silence = pcm(silent, silent)
        self.assertEqual(self.problems(silence, "silence"), [])
        problems = self.problems(silence)
        self.assertIn("left: spectrum peak at none, not 1000 Hz", problems)
        self.assertTrue(any("right: RMS 0.0000" in p for p in problems), problems)

    def test_a_tone_is_not_silence(self):
        problems = self.problems(self.tone, "silence")
        self.assertEqual([p.split(":")[0] for p in problems], ["left", "right"], problems)

    def test_one_quiet_sample_is_still_silence_but_a_faint_tone_is_not(self):
        self.assertEqual(
            self.problems(pcm(silent, silent)[:-4] + b"\x01\x00\x00\x00", "silence"), []
        )
        self.assertNotEqual(self.problems(pcm(sine(1000, 0.001), silent), "silence"), [])

    def test_a_wrong_frequency_fails(self):
        summary = self.probe.content_summary(pcm(sine(1100), sine(1500)), TONE)
        self.assertAlmostEqual(summary["peak_hz_left"], 1100, delta=6)
        self.assertEqual(
            summary["problems"],
            [
                f"left: spectrum peak at {summary['peak_hz_left']:.1f} Hz, not 1000 Hz",
                "left: 0.000 of the energy at 1000 Hz",
            ],
        )

    def test_a_near_frequency_outside_the_tolerance_fails(self):
        problems = self.problems(pcm(sine(1000), sine(1520)))
        self.assertTrue(any(p.startswith("right: spectrum peak") for p in problems), problems)

    def assert_swapped(self, data: bytes):
        summary = self.probe.content_summary(data, TONE)
        self.assertAlmostEqual(summary["peak_hz_left"], 1500, delta=6)
        self.assertAlmostEqual(summary["peak_hz_right"], 1000, delta=6)
        self.assertEqual(
            [p.split(" at ")[0] for p in summary["problems"]],
            ["left: spectrum peak", "left: 0.000 of the energy", "right: spectrum peak",
             "right: 0.000 of the energy"],
        )  # fmt: skip

    def test_swapped_channels_fail(self):
        self.assert_swapped(pcm(sine(1500), sine(1000)))

    def test_noise_fails(self):
        problems = self.problems(pcm(noise(2), noise(3)))
        self.assertTrue(any(p.startswith("left: 0.0") for p in problems), problems)
        self.assertTrue(any(p.startswith("right: 0.0") for p in problems), problems)

    def test_a_tone_too_quiet_or_too_loud_fails(self):
        for amplitude in (0.1, 0.6):
            with self.subTest(amplitude=amplitude):
                problems = self.problems(pcm(sine(1000, amplitude), sine(1500, amplitude)))
                self.assertEqual(sum("RMS" in p for p in problems), 2, problems)

    def test_less_than_a_second_fails(self):
        problems = self.problems(pcm(sine(1000), sine(1500), seconds=0.5))
        self.assertTrue(any("less than a second" in p for p in problems), problems)

    def test_a_stream_read_a_byte_off_fails(self):
        # What PCMPlayer would decode after dropping an odd-length message: every sample's
        # bytes straddle two samples.
        self.assertNotEqual(self.problems(self.tone[1:]), [])

    def test_a_stream_read_a_sample_off_has_its_channels_swapped(self):
        self.assert_swapped(self.tone[2:])

    def test_a_trailing_partial_frame_is_ignored(self):
        self.assertEqual(self.problems(self.tone + b"\x01\x02\x03"), [])

    def test_expect_must_be_silence_or_two_frequencies(self):
        for expect in ("tone:1000", "tone:,1500", "tone:a,b", "beep", ""):
            with self.subTest(expect=expect), self.assertRaises(ValueError):
                self.probe.parse_expect(expect)
        self.assertEqual(self.probe.parse_expect("tone:1000,1500"), (1000.0, 1500.0))
        self.assertIsNone(self.probe.parse_expect("silence"))


class SpectrumTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_probe()

    def test_fft_matches_a_direct_dft(self):
        rng = random.Random(4)
        values = [complex(rng.uniform(-1, 1), rng.uniform(-1, 1)) for _ in range(32)]
        n = len(values)
        expected = [
            sum(values[t] * cmath.exp(-2j * math.pi * k * t / n) for t in range(n))
            for k in range(n)
        ]
        for got, want in zip(self.probe.fft(values), expected, strict=True):
            self.assertAlmostEqual(got, want, places=9)

    def test_tone_fraction_is_one_for_a_pure_tone_and_zero_for_silence(self):
        samples = [0.25 * math.sin(2 * math.pi * 1000 * i / RATE) for i in range(RATE)]
        self.assertAlmostEqual(self.probe.tone_fraction(samples, 1000), 1.0, places=6)
        self.assertLess(self.probe.tone_fraction(samples, 1500), 1e-6)
        self.assertEqual(self.probe.tone_fraction([0.0] * RATE, 1000), 0.0)

    def test_peak_needs_enough_samples_and_some_signal(self):
        self.assertIsNone(self.probe.peak_hz([0.1] * 100))
        self.assertIsNone(self.probe.peak_hz([0.0] * 10000))
        samples = [math.sin(2 * math.pi * 3000 * i / RATE) for i in range(10000)]
        self.assertAlmostEqual(self.probe.peak_hz(samples), 3000, delta=6)


class StreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_probe()
        cls.tone = pcm(sine(1000), sine(1500))

    def messages(self, data: bytes, size: int = 1764, seconds_per_byte: float = 1 / 176400):
        """DATA cut into messages of SIZE bytes, each timed as it would arrive."""
        return [(i * seconds_per_byte, data[i : i + size]) for i in range(0, len(data), size)]

    def test_a_real_time_stream_passes(self):
        summary = self.probe.stream_summary(self.messages(self.tone), TONE)
        self.assertEqual(summary["problems"], [])
        self.assertAlmostEqual(summary["rate"], 176400, delta=200)
        self.assertEqual((summary["min_size"], summary["max_size"]), (1764, 1764))

    def test_messages_of_any_even_length_pass(self):
        # PCMPlayer joins messages into one stream of samples, so only odd lengths break it.
        summary = self.probe.stream_summary(self.messages(self.tone, size=1766), TONE)
        self.assertEqual(summary["problems"], [])
        self.assertGreater(summary["unaligned_messages"], 0)

    def test_a_stream_too_fast_or_too_slow_fails(self):
        for factor in (0.8, 1.2):
            with self.subTest(factor=factor):
                messages = self.messages(self.tone, seconds_per_byte=factor / 176400)
                problems = self.probe.stream_summary(messages, TONE)["problems"]
                self.assertEqual(len(problems), 1, problems)
                self.assertTrue(problems[0].startswith("rate "), problems)

    def test_an_odd_length_message_fails(self):
        messages = self.messages(self.tone)
        messages.insert(5, (messages[5][0], b"\x00"))
        problems = self.probe.stream_summary(messages, TONE)["problems"]
        self.assertIn("1 message(s) of an odd length, which PCMPlayer drops", problems)

    def test_too_few_messages_fail(self):
        for messages in ([], [(0.0, self.tone)]):
            with self.subTest(count=len(messages)):
                problems = self.probe.stream_summary(messages, "silence")["problems"]
                self.assertTrue(any("no rate to measure" in p for p in problems), problems)

    def test_no_data_is_not_silence(self):
        problems = self.probe.stream_summary([], "silence")["problems"]
        self.assertIn("left: no samples", problems)
        self.assertIn("right: no samples", problems)


class FrameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_probe()

    def test_accept_key_matches_rfc_6455(self):
        # The example in RFC 6455, section 1.3.
        self.assertEqual(
            self.probe.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )

    def test_each_length_encoding_parses(self):
        for length in (0, 125, 126, 65535, 65536, 70000):
            with self.subTest(length=length):
                payload = bytes(i % 251 for i in range(length))
                frame = server_frame(2, payload)
                self.assertEqual(
                    self.probe.parse_frame(frame + b"next"), ((True, 2, payload), len(frame))
                )

    def test_an_incomplete_frame_is_not_parsed_yet(self):
        frame = server_frame(2, bytes(300))
        for cut in range(len(frame)):
            with self.subTest(cut=cut):
                self.assertIsNone(self.probe.parse_frame(frame[:cut]))

    def test_frames_a_server_must_not_send_fail(self):
        cases = {
            "masked": bytes([0x82, 0x80 | 2]) + b"mask" + b"ab",
            "reserved bits": server_frame(2, b"ab", first_bits=0x40),
            "unknown opcode": server_frame(3, b"ab"),
            "fragmented ping": server_frame(9, b"", fin=False),
            "long ping": server_frame(9, bytes(126)),
        }
        for name, frame in cases.items():
            with self.subTest(name), self.assertRaises(self.probe.ProtocolError):
                self.probe.parse_frame(frame)

    def test_messages_are_joined_across_frames_and_reads(self):
        stream = (
            server_frame(2, b"one")
            + server_frame(2, b"tw", fin=False)
            + server_frame(9, b"ping")  # control frames may come between fragments
            + server_frame(0, b"o", fin=False)
            + server_frame(0, b"", fin=True)
            + server_frame(2, bytes(1764))
        )
        expected = [(2, b"one"), (9, b"ping"), (2, b"two"), (2, bytes(1764))]
        whole = self.probe.MessageReader().feed(stream)
        self.assertEqual(whole, expected)
        reader = self.probe.MessageReader()
        bytewise = [event for i in range(len(stream)) for event in reader.feed(stream[i : i + 1])]
        self.assertEqual(bytewise, expected)

    def test_broken_fragmentation_fails(self):
        for name, stream in {
            "continuation first": server_frame(0, b"x"),
            "new message mid-way": server_frame(2, b"a", fin=False) + server_frame(2, b"b"),
        }.items():
            with self.subTest(name), self.assertRaises(self.probe.ProtocolError):
                self.probe.MessageReader().feed(stream)

    def test_client_frames_are_masked(self):
        for length in (0, 2, 125, 126, 70000):
            with self.subTest(length=length):
                payload = bytes(i % 7 for i in range(length))
                frame = self.probe.encode_client_frame(10, payload, b"\x01\x02\x03\x04")
                self.assertEqual(unmask_client_frame(frame), (10, payload))

    def test_the_handshake_is_checked(self):
        key = "dGhlIHNhbXBsZSBub25jZQ=="
        good = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: upgrade",
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            "Sec-WebSocket-Protocol: binary",
        ]
        self.probe.check_handshake("\r\n".join(good).encode(), key)
        for name, lines in {
            "404": ["HTTP/1.1 404 Not Found", *good[1:]],
            "no upgrade": [good[0], *good[2:]],
            "wrong accept": [*good[:3], "Sec-WebSocket-Accept: AAAA", good[4]],
            "no subprotocol": good[:4],
        }.items():
            with self.subTest(name), self.assertRaises(self.probe.ProtocolError):
                self.probe.check_handshake("\r\n".join(lines).encode(), key)


class FakeAudioServer:
    """A WebSocket server on 127.0.0.1 that streams PCM in 1,764-byte messages in real time,
    pinging first; or, with STATUS, answers the handshake with that HTTP status."""

    def __init__(self, data: bytes, status: str = "101 Switching Protocols") -> None:
        self.data, self.status = data, status
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.pong = None
        self.request = b""
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        connection, _ = self.listener.accept()
        with connection:
            while b"\r\n\r\n" not in self.request:
                self.request += connection.recv(4096)
            key = next(
                line.split(":", 1)[1].strip()
                for line in self.request.decode().split("\r\n")
                if line.lower().startswith("sec-websocket-key:")
            )
            accept = base64.b64encode(
                hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            ).decode()
            connection.sendall(
                f"HTTP/1.1 {self.status}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: binary\r\n\r\n".encode()
            )
            if not self.status.startswith("101"):
                return
            connection.sendall(server_frame(9, b"hi"))
            connection.settimeout(5)
            pong = connection.recv(4096)
            self.pong = unmask_client_frame(pong)
            start = time.monotonic()
            for i in range(0, len(self.data), 1764):
                delay = start + i / 176400 - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                try:
                    connection.sendall(server_frame(2, self.data[i : i + 1764]))
                except OSError:
                    return

    def close(self) -> None:
        self.thread.join(timeout=10)
        self.listener.close()


class CaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_probe()

    def test_a_real_time_stream_is_captured_and_passes(self):
        server = FakeAudioServer(pcm(sine(1000), sine(1500), seconds=3))
        try:
            messages = self.probe.capture("127.0.0.1", server.port, 1.6)
        finally:
            server.close()
        self.assertIn(b"Sec-WebSocket-Protocol: binary\r\n", server.request)
        self.assertIn(b"GET /websockify-audio HTTP/1.1\r\n", server.request)
        self.assertEqual(server.pong, (10, b"hi"))
        summary = self.probe.stream_summary(messages, TONE)
        self.assertEqual(summary["problems"], [])
        self.assertAlmostEqual(summary["rate"], 176400, delta=176400 * 0.15)

    def test_the_command_line_reports_a_refused_handshake(self):
        server = FakeAudioServer(b"", status="404 Not Found")
        try:
            result = subprocess.run(
                [sys.executable, "-I", str(PROBE), "ws", "127.0.0.1", str(server.port), "1", TONE],
                capture_output=True, text=True, timeout=30, check=False,
            )  # fmt: skip
        finally:
            server.close()
        self.assertEqual(result.returncode, 1, result.stderr)
        problems = json.loads(result.stdout)["problems"]
        self.assertEqual(
            problems,
            ["ProtocolError: expected 101 Switching Protocols, got 'HTTP/1.1 404 Not Found'"],
        )

    def test_the_command_line_checks_a_raw_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "raw.pcm"
            path.write_bytes(pcm(sine(1000), sine(1500)))
            for expect, status in ((TONE, 0), ("silence", 1), ("tone:1500,1000", 1)):
                with self.subTest(expect=expect):
                    result = subprocess.run(
                        [sys.executable, "-I", str(PROBE), "raw", str(path), expect],
                        capture_output=True, text=True, timeout=30, check=False,
                    )  # fmt: skip
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    summary = json.loads(result.stdout)
                    self.assertEqual(summary["bytes"], path.stat().st_size)
                    self.assertEqual(bool(summary["problems"]), bool(status))

    def test_wrong_arguments_print_the_usage(self):
        for args in ([], ["ws", "h", "1", "1"], ["raw", "f", "beep"], ["ws", "h", "x", "1", TONE]):
            with self.subTest(args=args):
                result = subprocess.run(
                    [sys.executable, "-I", str(PROBE), *args],
                    capture_output=True, text=True, timeout=30, check=False,
                )  # fmt: skip
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage: ws_audio_probe.py ws HOST PORT SECONDS EXPECT", result.stderr)


if __name__ == "__main__":
    unittest.main()
