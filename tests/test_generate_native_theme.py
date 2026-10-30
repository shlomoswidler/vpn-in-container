"""Tests for config/cursors/generate_native_theme.py.

Run: python3 -m unittest discover -s tests
"""

import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR = REPO_ROOT / "config" / "cursors" / "generate_native_theme.py"
COMMITTED_THEME = REPO_ROOT / "config" / "cursors" / "native-css"
NOVNC_KEYWORDS = REPO_ROOT / "config" / "novnc" / "cursor-keyword.js"

spec = importlib.util.spec_from_file_location("generate_native_theme", GENERATOR)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


def read_xcursor(path: Path) -> dict:
    """Parse a single-image Xcursor file independently of the generator."""
    data = path.read_bytes()
    magic, header_len, version, ntoc = struct.unpack_from("<4sIII", data, 0)
    if magic != b"Xcur" or header_len != 16 or version != 0x10000:
        raise ValueError(f"{path}: bad file header")
    toc_type, nominal, pos = struct.unpack_from("<III", data, header_len)
    fields = struct.unpack_from("<9I", data, pos)
    width, height = fields[4], fields[5]
    pixels = struct.unpack_from(f"<{width * height}I", data, pos + fields[0])
    if pos + fields[0] + 4 * width * height != len(data):
        raise ValueError(f"{path}: trailing or missing bytes")
    return {
        "ntoc": ntoc,
        "toc_type": toc_type,
        "nominal": nominal,
        "chunk_type": fields[1],
        "chunk_nominal": fields[2],
        "width": width,
        "height": height,
        "hot": (fields[6], fields[7]),
        "delay": fields[8],
        "argb": pixels,
    }


def read_xcursor_bytes(data: bytes) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "cursor"
        path.write_bytes(data)
        return read_xcursor(path)


def decode_marker(argb: tuple[int, ...]) -> str:
    """Decode the marker format from its spec (not from the generator)."""
    rgb = [((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in argb]
    if any(p >> 24 != 0xFF for p in argb):
        raise ValueError("marker pixel is not opaque")
    if bytes(rgb[0]) != b"css" or rgb[1][1:] != (0, 1):
        raise ValueError("bad marker header")
    length = rgb[1][0]
    chars = b"".join(bytes(px) for px in rgb[2:])
    if len(rgb) != 2 + -(-length // 3) or any(chars[length:]):
        raise ValueError("bad marker length or padding")
    return chars[:length].decode("ascii")


class MarkerTests(unittest.TestCase):
    def test_round_trips_every_keyword(self):
        for keyword in gen.KEYWORDS:
            with self.subTest(keyword=keyword):
                pixels = gen.marker_pixels(keyword)
                argb = tuple(0xFF000000 | r << 16 | g << 8 | b for r, g, b in pixels)
                self.assertEqual(decode_marker(argb), keyword)

    def test_rejects_empty_and_overlong_keywords(self):
        for keyword in ("", "x" * 256):
            with self.subTest(length=len(keyword)), self.assertRaises(ValueError):
                gen.marker_pixels(keyword)

    def test_rejects_non_ascii_keyword(self):
        with self.assertRaises(UnicodeEncodeError):
            gen.marker_pixels("défault")


class XcursorFileTests(unittest.TestCase):
    def test_file_layout(self):
        parsed = read_xcursor_bytes(gen.xcursor_file(gen.marker_pixels("pointer"), 24))
        self.assertEqual(parsed["ntoc"], 1)
        self.assertEqual(parsed["toc_type"], 0xFFFD0002)
        self.assertEqual(parsed["chunk_type"], 0xFFFD0002)
        self.assertEqual((parsed["nominal"], parsed["chunk_nominal"]), (24, 24))
        self.assertEqual((parsed["width"], parsed["height"]), (5, 1))
        self.assertEqual(parsed["hot"], (0, 0))
        self.assertEqual(parsed["delay"], 0)
        self.assertEqual(decode_marker(parsed["argb"]), "pointer")


class GenerateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.out = Path(self._tmp.name) / "theme"

    def tearDown(self):
        self._tmp.cleanup()

    def test_writes_keywords_aliases_and_index(self):
        names = gen.generate(self.out)
        cursors = self.out / "cursors"
        self.assertEqual(sorted(p.name for p in cursors.iterdir()), names)
        for keyword in gen.KEYWORDS:
            path = cursors / keyword
            self.assertFalse(path.is_symlink(), keyword)
            self.assertEqual(decode_marker(read_xcursor(path)["argb"]), keyword)
        for alias, keyword in gen.ALIASES.items():
            path = cursors / alias
            self.assertTrue(path.is_symlink(), alias)
            self.assertEqual(str(path.readlink()), keyword, "relative link")
            self.assertEqual(decode_marker(read_xcursor(path)["argb"]), keyword)
        index = (self.out / "index.theme").read_text(encoding="ascii")
        self.assertIn("Name=native-css\n", index)
        self.assertNotIn("Inherits=", index)

    def test_removes_stale_files_and_replaces_links(self):
        cursors = self.out / "cursors"
        cursors.mkdir(parents=True)
        (cursors / "obsolete").write_bytes(b"old")
        (cursors / "default").symlink_to("obsolete")
        (cursors / "dnd-move").write_bytes(b"not a link")
        gen.generate(self.out)
        self.assertFalse((cursors / "obsolete").exists())
        self.assertFalse((cursors / "default").is_symlink())
        self.assertTrue((cursors / "dnd-move").is_symlink())

    def test_is_idempotent(self):
        gen.generate(self.out)
        first = snapshot(self.out)
        gen.generate(self.out)
        self.assertEqual(snapshot(self.out), first)

    def test_committed_theme_is_up_to_date(self):
        gen.generate(self.out)
        self.assertEqual(
            snapshot(COMMITTED_THEME),
            snapshot(self.out),
            "run config/cursors/generate_native_theme.py",
        )

    def test_keywords_match_novnc_allow_list(self):
        source = NOVNC_KEYWORDS.read_text(encoding="utf-8")
        block = source.split("NATIVE_KEYWORDS = new Set([", 1)[1].split("]);", 1)[0]
        js_keywords = {
            w.strip().strip("'") for w in block.replace("\n", " ").split(",") if w.strip()
        }
        self.assertEqual(js_keywords, set(gen.KEYWORDS))

    def test_rejects_bad_alias_table(self):
        cases = {
            "unknown target": {"hand2": "hand"},
            "shadows keyword": {"pointer": "default"},
        }
        for name, aliases in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                original = gen.ALIASES
                gen.ALIASES = aliases
                try:
                    gen.generate(self.out)
                finally:
                    gen.ALIASES = original


def snapshot(theme: Path) -> dict:
    out = {}
    for path in sorted(theme.rglob("*")):
        rel = str(path.relative_to(theme))
        if path.is_symlink():
            out[rel] = ("link", str(path.readlink()))
        elif path.is_file():
            out[rel] = ("file", path.read_bytes())
    return out


if __name__ == "__main__":
    unittest.main()
