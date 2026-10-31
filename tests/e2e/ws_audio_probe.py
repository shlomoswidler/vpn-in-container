#!/usr/bin/env python3
"""Check the audio stream the web UI plays: its rate, its framing and what it carries.

With WEB_AUDIO=1 the image's recorder writes what Firefox plays as raw PCM (signed 16-bit
little-endian samples, two interleaved channels, left first, 44,100 frames a second) to
/tmp/vnc-audio.sock, and nginx relays it as WebSocket messages on /websockify-audio, which
the web UI's PCMPlayer (/opt/noVNC/app/pcm-player.min.js) decodes. PCMPlayer treats the
messages as one stream of samples, but drops a message whose length is not a whole number of
samples (2 bytes): every later sample would then be read a byte off, as noise.

`ws` mode connects as the web UI does (subprotocol "binary"), reads for SECONDS and checks:
  - the data rate, 176,400 B/s to within 15 %, measured from the first message to the last
  - that no message has an odd length
  - the content, per EXPECT, in the stream PCMPlayer would decode (every message joined):
    "silence": both channels' RMS below 1e-4 (full scale is 1)
    "tone:LEFT_HZ,RIGHT_HZ": on each channel, over its last second, the spectrum's peak within
      10 Hz of that channel's frequency, at least half the signal's energy at that frequency,
      and an RMS within a factor of 2 of a 0.25 amplitude sine's (tests/e2e/audio-page.html)
`raw` mode checks the content of FILE, a capture of the recorder's socket (the step before
nginx), the same way; its rate is not checked, since the capture's length is not known exactly.

Prints a JSON summary; "problems" lists every check that failed. Exit status 0 when there is
none, 1 when there is, 2 for a usage error.

Usage: ws_audio_probe.py ws HOST PORT SECONDS EXPECT
       ws_audio_probe.py raw FILE EXPECT
"""

import base64
import cmath
import hashlib
import json
import math
import os
import socket
import struct
import sys
import time

PATH = "/websockify-audio"
SUBPROTOCOL = "binary"
# RFC 6455, section 1.3: the server proves it read the key by hashing it with this.
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OPCODE_CONTINUATION = 0x0
OPCODE_TEXT = 0x1
OPCODE_BINARY = 0x2
OPCODE_CLOSE = 0x8
OPCODE_PING = 0x9
OPCODE_PONG = 0xA
DATA_OPCODES = (OPCODE_CONTINUATION, OPCODE_TEXT, OPCODE_BINARY)
CONTROL_OPCODES = (OPCODE_CLOSE, OPCODE_PING, OPCODE_PONG)

RATE = 44100
CHANNELS = 2
SAMPLE_BYTES = 2
FRAME_BYTES = CHANNELS * SAMPLE_BYTES
BYTE_RATE = RATE * FRAME_BYTES
RATE_TOLERANCE = 0.15
SILENCE_RMS = 1e-4
TONE_AMPLITUDE = 0.25
TONE_RMS = TONE_AMPLITUDE / math.sqrt(2)
RMS_FACTOR = 2.0
PEAK_TOLERANCE_HZ = 10.0
MIN_TONE_FRACTION = 0.5
# The peak search: a Hann-windowed FFT of the last FFT_SIZE frames (5.4 Hz bins at 44.1 kHz).
FFT_SIZE = 8192
CONNECT_TIMEOUT_S = 10


class ProtocolError(Exception):
    """The server broke the WebSocket protocol (RFC 6455)."""


def accept_key(key: str) -> str:
    """The Sec-WebSocket-Accept value a server must answer KEY with."""
    digest = hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def check_handshake(response: bytes, key: str) -> None:
    """Raise ProtocolError unless RESPONSE (the head, up to the blank line) accepts KEY."""
    lines = response.decode("iso-8859-1").split("\r\n")
    status = lines[0].split(" ", 2)
    if len(status) < 2 or status[1] != "101":
        raise ProtocolError(f"expected 101 Switching Protocols, got {lines[0]!r}")
    headers = {}
    for line in lines[1:]:
        if line:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
    if headers.get("upgrade", "").lower() != "websocket":
        raise ProtocolError(f"Upgrade is {headers.get('upgrade')!r}, not websocket")
    if headers.get("sec-websocket-accept") != accept_key(key):
        raise ProtocolError(f"wrong Sec-WebSocket-Accept {headers.get('sec-websocket-accept')!r}")
    if headers.get("sec-websocket-protocol") != SUBPROTOCOL:
        raise ProtocolError(
            f"subprotocol {headers.get('sec-websocket-protocol')!r}, not {SUBPROTOCOL!r}"
        )


def encode_client_frame(opcode: int, payload: bytes, mask: bytes) -> bytes:
    """A final client frame: clients must mask every frame with a 4-byte MASK (RFC 6455 5.3)."""
    length = len(payload)
    if length < 126:
        head = struct.pack("!BB", 0x80 | opcode, 0x80 | length)
    elif length < 1 << 16:
        head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, length)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, length)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def parse_frame(buffer: bytes, offset: int = 0) -> tuple[tuple[bool, int, bytes], int] | None:
    """The server frame at OFFSET in BUFFER as ((fin, opcode, payload), next offset).

    None if the frame is not complete yet. Raises ProtocolError for what a server must not
    send: a masked frame, reserved bits, an unknown opcode, or a fragmented or oversized
    control frame.
    """
    if len(buffer) - offset < 2:
        return None
    first, second = buffer[offset], buffer[offset + 1]
    fin, opcode, length = bool(first & 0x80), first & 0x0F, second & 0x7F
    if first & 0x70:
        raise ProtocolError(f"reserved bits set: {first:#04x}")
    if second & 0x80:
        raise ProtocolError("the server masked a frame")
    if opcode not in DATA_OPCODES + CONTROL_OPCODES:
        raise ProtocolError(f"unknown opcode {opcode:#x}")
    position = offset + 2
    if length == 126:
        if len(buffer) - position < 2:
            return None
        (length,) = struct.unpack_from("!H", buffer, position)
        position += 2
    elif length == 127:
        if len(buffer) - position < 8:
            return None
        (length,) = struct.unpack_from("!Q", buffer, position)
        position += 8
    if opcode in CONTROL_OPCODES and (not fin or length > 125):
        raise ProtocolError(f"control frame {opcode:#x}: fin={fin} length={length}")
    if len(buffer) - position < length:
        return None
    return (fin, opcode, bytes(buffer[position : position + length])), position + length


class MessageReader:
    """Turns the bytes a server sends into messages, joining fragmented ones."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.fragments: list[bytes] = []
        self.fragment_opcode: int | None = None

    def feed(self, data: bytes) -> list[tuple[int, bytes]]:
        """The complete messages (opcode, payload) and control frames DATA finishes."""
        self.buffer += data
        events = []
        offset = 0
        while (parsed := parse_frame(self.buffer, offset)) is not None:
            (fin, opcode, payload), offset = parsed
            if opcode in CONTROL_OPCODES:
                events.append((opcode, payload))
                continue
            if opcode == OPCODE_CONTINUATION:
                if self.fragment_opcode is None:
                    raise ProtocolError("a continuation frame without a message to continue")
            elif self.fragment_opcode is not None:
                raise ProtocolError("a new message before the fragmented one ended")
            else:
                self.fragment_opcode = opcode
            self.fragments.append(payload)
            if fin:
                events.append((self.fragment_opcode, b"".join(self.fragments)))
                self.fragments, self.fragment_opcode = [], None
        del self.buffer[:offset]
        return events


def capture(host: str, port: int, seconds: float) -> list[tuple[float, bytes]]:
    """Each binary message the server sends in SECONDS, with its arrival time (monotonic s)."""
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {PATH} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Protocol: {SUBPROTOCOL}\r\n\r\n"
    )
    messages = []
    with socket.create_connection((host, port), timeout=CONNECT_TIMEOUT_S) as sock:
        sock.sendall(request.encode("ascii"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                raise ProtocolError(
                    f"the server closed the connection during the handshake: {head!r}"
                )
            head += chunk
        head, _, rest = head.partition(b"\r\n\r\n")
        check_handshake(head, key)
        reader = MessageReader()
        pending = reader.feed(rest)
        deadline = time.monotonic() + seconds
        while True:
            for opcode, payload in pending:
                if opcode == OPCODE_BINARY:
                    messages.append((time.monotonic(), payload))
                elif opcode == OPCODE_PING:
                    sock.sendall(encode_client_frame(OPCODE_PONG, payload, os.urandom(4)))
                elif opcode == OPCODE_CLOSE:
                    raise ProtocolError(f"the server closed the stream: {payload!r}")
                elif opcode == OPCODE_TEXT:
                    raise ProtocolError(f"a text message on a binary stream: {payload[:40]!r}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data = sock.recv(65536)
            except TimeoutError:
                break
            if not data:
                raise ProtocolError("the server closed the connection")
            pending = reader.feed(data)
        sock.sendall(encode_client_frame(OPCODE_CLOSE, struct.pack("!H", 1000), os.urandom(4)))
    return messages


def decode(pcm: bytes) -> tuple[list[float], list[float]]:
    """The left and right channels of PCM (whole frames only), scaled to [-1, 1)."""
    frames = len(pcm) // FRAME_BYTES
    samples = struct.unpack(f"<{frames * CHANNELS}h", pcm[: frames * FRAME_BYTES])
    return [s / 32768 for s in samples[0::2]], [s / 32768 for s in samples[1::2]]


def rms(samples: list[float]) -> float:
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0.0


def tone_fraction(samples: list[float], hz: float, rate: int = RATE) -> float:
    """The share of SAMPLES' energy at HZ (Goertzel): 1 for a sine of whole cycles, 0 for silence."""
    energy = sum(x * x for x in samples)
    if energy == 0:
        return 0.0
    coefficient = 2 * math.cos(2 * math.pi * hz / rate)
    s1 = s2 = 0.0
    for x in samples:
        s1, s2 = x + coefficient * s1 - s2, s1
    power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
    return 2 * power / (len(samples) * energy)


def fft(values: list[complex]) -> list[complex]:
    """Iterative radix-2 FFT; len(VALUES) must be a power of two."""
    n = len(values)
    out = list(values)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    size = 2
    while size <= n:
        step = cmath.exp(-2j * math.pi / size)
        for start in range(0, n, size):
            w = 1 + 0j
            for k in range(start, start + size // 2):
                even, odd = out[k], out[k + size // 2] * w
                out[k], out[k + size // 2] = even + odd, even - odd
                w *= step
        size *= 2
    return out


def peak_hz(samples: list[float], rate: int = RATE) -> float | None:
    """The frequency of the strongest bin of the last FFT_SIZE samples (Hann window).

    None if there are fewer samples, or they are silent.
    """
    if len(samples) < FFT_SIZE:
        return None
    window = samples[-FFT_SIZE:]
    hann = [
        x * (0.5 - 0.5 * math.cos(2 * math.pi * i / (FFT_SIZE - 1))) for i, x in enumerate(window)
    ]
    magnitudes = [abs(v) for v in fft([complex(x) for x in hann])[1 : FFT_SIZE // 2]]
    strongest = max(magnitudes)
    if strongest == 0:
        return None
    return (magnitudes.index(strongest) + 1) * rate / FFT_SIZE


def parse_expect(expect: str) -> tuple[float, float] | None:
    """EXPECT as (left Hz, right Hz) for "tone:L,R", None for "silence"; ValueError otherwise."""
    if expect == "silence":
        return None
    kind, _, frequencies = expect.partition(":")
    left, _, right = frequencies.partition(",")
    if kind != "tone" or not left or not right:
        raise ValueError(f"EXPECT must be silence or tone:LEFT_HZ,RIGHT_HZ, not {expect!r}")
    return float(left), float(right)


def content_summary(pcm: bytes, expect: str) -> dict:
    """What PCM carries, and the problems with it for EXPECT (see the module docstring)."""
    tones = parse_expect(expect)
    left, right = decode(pcm)
    summary = {"expect": expect, "frames": len(left), "problems": []}
    problems = summary["problems"]
    for name, samples, hz in (
        ("left", left, tones and tones[0]),
        ("right", right, tones and tones[1]),
    ):
        if tones is None:
            level = rms(samples)
            summary[f"rms_{name}"] = round(level, 6)
            if not samples:
                problems.append(f"{name}: no samples")
            elif level >= SILENCE_RMS:
                problems.append(f"{name}: RMS {level:.6f} is not silence (< {SILENCE_RMS})")
            continue
        last_second = samples[-RATE:]
        level = rms(last_second)
        peak = peak_hz(last_second)
        fraction = tone_fraction(last_second, hz)
        summary[f"rms_{name}"] = round(level, 6)
        summary[f"peak_hz_{name}"] = peak and round(peak, 1)
        summary[f"tone_fraction_{name}"] = round(fraction, 4)
        if len(last_second) < RATE:
            problems.append(f"{name}: {len(last_second)} frames, less than a second")
        if peak is None or abs(peak - hz) > PEAK_TOLERANCE_HZ:
            shown = "none" if peak is None else f"{peak:.1f} Hz"
            problems.append(f"{name}: spectrum peak at {shown}, not {hz:g} Hz")
        if fraction < MIN_TONE_FRACTION:
            problems.append(f"{name}: {fraction:.3f} of the energy at {hz:g} Hz")
        if not TONE_RMS / RMS_FACTOR <= level <= TONE_RMS * RMS_FACTOR:
            problems.append(f"{name}: RMS {level:.4f}, not within x{RMS_FACTOR} of {TONE_RMS:.4f}")
    return summary


def stream_summary(messages: list[tuple[float, bytes]], expect: str) -> dict:
    """content_summary of MESSAGES joined, with the checks of their rate and lengths."""
    sizes = [len(payload) for _, payload in messages]
    pcm = b"".join(payload for _, payload in messages)
    summary = content_summary(pcm, expect)
    problems = summary.pop("problems")
    odd = sum(1 for size in sizes if size % SAMPLE_BYTES)
    rate = None
    if len(messages) >= 2 and messages[-1][0] > messages[0][0]:
        rate = (len(pcm) - sizes[0]) / (messages[-1][0] - messages[0][0])
    summary.update(
        messages=len(messages),
        bytes=len(pcm),
        rate=rate and round(rate),
        min_size=min(sizes, default=0),
        max_size=max(sizes, default=0),
        odd_messages=odd,
        unaligned_messages=sum(1 for size in sizes if size % FRAME_BYTES),
    )
    stream_problems = []
    if rate is None:
        stream_problems.append(f"{len(messages)} message(s): no rate to measure")
    elif abs(rate - BYTE_RATE) > BYTE_RATE * RATE_TOLERANCE:
        stream_problems.append(f"rate {rate:.0f} B/s, not {BYTE_RATE} B/s +-{RATE_TOLERANCE:.0%}")
    if odd:
        stream_problems.append(f"{odd} message(s) of an odd length, which PCMPlayer drops")
    summary["problems"] = stream_problems + problems
    return summary


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 5 and argv[0] == "ws":
            host, port, seconds, expect = argv[1], int(argv[2]), float(argv[3]), argv[4]
        elif len(argv) == 3 and argv[0] == "raw":
            path, expect = argv[1], argv[2]
        else:
            raise ValueError("wrong arguments")
        parse_expect(expect)
    except ValueError as err:
        print(f"{err}\n{__doc__}", file=sys.stderr)
        return 2
    try:
        if argv[0] == "ws":
            summary = stream_summary(capture(host, port, seconds), expect)
        else:
            with open(path, "rb") as capture_file:
                pcm = capture_file.read()
            summary = content_summary(pcm, expect)
            summary["bytes"] = len(pcm)
            summary["problems"] = summary.pop("problems")
    except (ProtocolError, OSError) as err:
        summary = {"expect": expect, "problems": [f"{type(err).__name__}: {err}"]}
    print(json.dumps(summary))
    return 1 if summary["problems"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
