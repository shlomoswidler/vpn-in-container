#!/usr/bin/env python3
"""Generate the "native-css" Xcursor theme.

Every cursor in the theme is a marker image that names a CSS cursor keyword
instead of drawing a cursor. The patched noVNC client (config/novnc/
cursor-keyword.js) decodes the marker and lets the viewer's browser draw its
own native cursor for that keyword, so the remote cursor matches the local OS.

Marker image (1 pixel tall, every pixel fully opaque):
    pixel 0: R, G, B = "css" (0x63, 0x73, 0x73)
    pixel 1: R = keyword length, G = 0, B = format version (1)
    pixel 2..: the keyword in ASCII, three characters per pixel, zero padded

Firefox on X11 (GTK 3) requests each CSS cursor by its CSS name. Names that
are not CSS keywords are symlinks to the matching keyword file.

The theme inherits from no other theme. If a requested name is missing, GDK
tries one legacy name and then left_ptr (a marker for "default" here), so the
viewer sees its native arrow. GDK names that exist in the X core cursor font
(crosshair, for example) fall back to that 1-bit glyph instead, which is one
reason every CSS keyword has its own file.

Usage: python3 config/cursors/generate_native_theme.py [--out DIR]
"""

import argparse
import struct
import sys
from pathlib import Path

THEME_NAME = "native-css"
# Must match XCURSOR_SIZE in docker-compose.yml so libXcursor never rescales.
NOMINAL_SIZE = 24

MAGIC = b"css"
FORMAT_VERSION = 1
CHARS_PER_PIXEL = 3

# CSS cursor keywords (CSS Basic User Interface Level 4) without "auto" and
# "none", which never reach the theme. Keep in sync with NATIVE_KEYWORDS in
# config/novnc/cursor-keyword.js.
KEYWORDS = (
    "default", "context-menu", "help", "pointer", "progress", "wait",
    "cell", "crosshair", "text", "vertical-text", "alias", "copy", "move",
    "no-drop", "not-allowed", "grab", "grabbing", "all-scroll",
    "col-resize", "row-resize", "n-resize", "e-resize", "s-resize",
    "w-resize", "ne-resize", "nw-resize", "se-resize", "sw-resize",
    "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
    "zoom-in", "zoom-out",
)  # fmt: skip

# Non-CSS names GDK requests, mapped to the keyword they stand for.
# dnd-*: drag-and-drop cursors, which have no fallback in GDK.
# left_ptr: GDK's last-resort name for any cursor it cannot otherwise find.
ALIASES = {
    "dnd-ask": "copy",
    "dnd-link": "alias",
    "dnd-move": "move",
    "left_ptr": "default",
}

XCURSOR_MAGIC = b"Xcur"
XCURSOR_FILE_HEADER_LEN = 16
XCURSOR_FILE_VERSION = 0x0001_0000
XCURSOR_IMAGE_TYPE = 0xFFFD_0002
XCURSOR_IMAGE_HEADER_LEN = 36
XCURSOR_IMAGE_VERSION = 1
TOC_ENTRY_LEN = 12


def marker_pixels(keyword: str) -> list[tuple[int, int, int]]:
    """Return the marker image for keyword as opaque (R, G, B) pixels."""
    data = keyword.encode("ascii")
    if not 0 < len(data) <= 0xFF:
        raise ValueError(f"keyword length out of range: {keyword!r}")
    data += b"\0" * (-len(data) % CHARS_PER_PIXEL)
    pixels = [tuple(MAGIC), (len(keyword), 0, FORMAT_VERSION)]
    pixels += [tuple(data[i : i + CHARS_PER_PIXEL]) for i in range(0, len(data), CHARS_PER_PIXEL)]
    return pixels


def xcursor_file(pixels: list[tuple[int, int, int]], nominal_size: int) -> bytes:
    """Encode a single-image, 1 pixel tall Xcursor file with hotspot (0, 0)."""
    image_pos = XCURSOR_FILE_HEADER_LEN + TOC_ENTRY_LEN
    out = struct.pack("<4sIII", XCURSOR_MAGIC, XCURSOR_FILE_HEADER_LEN, XCURSOR_FILE_VERSION, 1)
    out += struct.pack("<III", XCURSOR_IMAGE_TYPE, nominal_size, image_pos)
    out += struct.pack(
        "<9I",
        XCURSOR_IMAGE_HEADER_LEN,
        XCURSOR_IMAGE_TYPE,
        nominal_size,
        XCURSOR_IMAGE_VERSION,
        len(pixels),  # width
        1,  # height
        0,  # xhot
        0,  # yhot
        0,  # delay (single frame)
    )
    for r, g, b in pixels:
        out += struct.pack("<I", 0xFF00_0000 | r << 16 | g << 8 | b)
    return out


def index_theme() -> str:
    return (
        "[Icon Theme]\n"
        f"Name={THEME_NAME}\n"
        "Comment=Marker cursors naming CSS cursor keywords, decoded by the patched noVNC client\n"
    )


def generate(out_dir: Path) -> list[str]:
    """Write the theme into out_dir and return the cursor names it contains.

    Files in out_dir/cursors that the theme does not define are removed, so
    the directory always matches KEYWORDS and ALIASES exactly.
    """
    unknown = sorted(set(ALIASES.values()) - set(KEYWORDS))
    if unknown:
        raise ValueError(f"aliases point at unknown keywords: {unknown}")
    clashes = sorted(set(ALIASES) & set(KEYWORDS))
    if clashes:
        raise ValueError(f"aliases shadow keywords: {clashes}")

    cursors = out_dir / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)
    wanted = set(KEYWORDS) | set(ALIASES)
    for stale in cursors.iterdir():
        if stale.name not in wanted:
            stale.unlink()

    for keyword in KEYWORDS:
        path = cursors / keyword
        if path.is_symlink():
            path.unlink()
        path.write_bytes(xcursor_file(marker_pixels(keyword), NOMINAL_SIZE))
    for alias, keyword in ALIASES.items():
        path = cursors / alias
        if path.is_symlink() or path.exists():
            path.unlink()
        path.symlink_to(keyword)

    (out_dir / "index.theme").write_text(index_theme(), encoding="ascii")
    return sorted(wanted)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent / THEME_NAME,
        help=f"theme directory to write (default: config/cursors/{THEME_NAME})",
    )
    args = parser.parse_args(argv)
    names = generate(args.out)
    print(f"wrote {len(names)} cursors to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
