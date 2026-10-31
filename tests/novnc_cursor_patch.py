#!/usr/bin/env python3
"""Check that config/novnc/cursor.js is the image's noVNC cursor.js plus cursor.js.patch.

The firefox service mounts config/novnc/cursor.js over the image's
/opt/noVNC/core/util/cursor.js, so a new image's version of that file would be hidden, with
its fixes. config/novnc/cursor.js.upstream.sha256 records the checksum of the file the
overlay was made from, and config/novnc/cursor.js.patch the change (`diff -u` output).

Given the image's file (copied out of the image with `docker create` and `docker cp`), this
exits 0 if it has the recorded checksum and the patch turns it into config/novnc/cursor.js;
otherwise it says which and exits 1. The patch is applied strictly: every hunk must match
exactly where it says, with no offset and no fuzz (unlike `patch`). The unit tests
(tests/test_novnc_cursor_patch.py) check the overlay without the image's file, by taking the
patch back out of it. config/cursors/README.md says how to update all three files.

Usage: python3 -I tests/novnc_cursor_patch.py IMAGE_CURSOR_JS
"""

import hashlib
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parent.parent
NOVNC_DIR = REPO_ROOT / "config" / "novnc"
OVERLAY = NOVNC_DIR / "cursor.js"
PATCH_FILE = NOVNC_DIR / "cursor.js.patch"
CHECKSUM_FILE = NOVNC_DIR / "cursor.js.upstream.sha256"
# One `sha256sum` line: the digest, two spaces, the file's path under /opt/noVNC.
CHECKSUM_LINE = re.compile(r"\A([0-9a-f]{64})  core/util/cursor\.js\n\Z")
HUNK_HEADER = re.compile(rb"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?\n\Z")


class PatchError(Exception):
    """The patch cannot be read, or does not apply, or gives the wrong file."""


class Hunk(NamedTuple):
    number: int  # 1-based, for messages
    old_start: int
    new_start: int
    # Each line with its prefix: b" " context, b"-" removed, b"+" added; content ends in \n.
    lines: tuple[bytes, ...]


def split_lines(data: bytes) -> list[bytes]:
    """DATA's lines, each ending in a newline; raise PatchError if the last one has none."""
    if data and not data.endswith(b"\n"):
        raise PatchError("a file without a newline at its end is not supported")
    # Not bytes.splitlines, which also splits on \r: diff and patch split only on \n.
    return [line + b"\n" for line in data.split(b"\n")[:-1]]


def parse_patch(text: bytes) -> list[Hunk]:
    """The hunks of a one-file unified diff; raise PatchError on anything else."""
    lines = split_lines(text)
    if len(lines) < 2 or not lines[0].startswith(b"--- ") or not lines[1].startswith(b"+++ "):
        raise PatchError("the patch does not start with a ---/+++ file header")
    hunks: list[Hunk] = []
    index = 2
    while index < len(lines):
        header = HUNK_HEADER.match(lines[index])
        if not header:
            raise PatchError(
                f"line {index + 1} of the patch is not a hunk header: {lines[index]!r}"
            )
        old_start, old_count, new_start, new_count = (
            int(value) if value is not None else 1 for value in header.groups()
        )
        number = len(hunks) + 1
        index += 1
        body = []
        old_seen = new_seen = 0
        while old_seen < old_count or new_seen < new_count:
            if index == len(lines):
                raise PatchError(f"hunk {number} ends before its {old_count},{new_count} lines")
            line = lines[index]
            prefix = line[:1]
            if prefix == b" ":
                old_seen += 1
                new_seen += 1
            elif prefix == b"-":
                old_seen += 1
            elif prefix == b"+":
                new_seen += 1
            elif line.startswith(b"\\"):
                raise PatchError(
                    f"hunk {number}, line {index + 1}: a missing final newline is not supported"
                )
            else:
                raise PatchError(
                    f"hunk {number}: line {index + 1} of the patch is not a hunk line: {line!r}"
                )
            body.append(line)
            index += 1
        if old_seen != old_count or new_seen != new_count:
            raise PatchError(
                f"hunk {number} has {old_seen},{new_seen} lines, its header says "
                f"{old_count},{new_count}"
            )
        hunks.append(Hunk(number, old_start, new_start, tuple(body)))
    if not hunks:
        raise PatchError("the patch has no hunks")
    return hunks


def _first_index(start: int, count: int) -> int:
    # In a hunk header, a side with no lines names the line before the hunk.
    return start - 1 if count else start


def apply_patch(data: bytes, hunks: list[Hunk], reverse: bool = False) -> bytes:
    """DATA with the hunks applied (or, with REVERSE, taken back out); exact matches only."""
    source = split_lines(data)
    taken_prefix, given_prefix = (b"+", b"-") if reverse else (b"-", b"+")
    result: list[bytes] = []
    position = 0
    for hunk in hunks:
        taken = [line[1:] for line in hunk.lines if line[:1] in (b" ", taken_prefix)]
        given = [line[1:] for line in hunk.lines if line[:1] in (b" ", given_prefix)]
        from_start, to_start = (
            (hunk.new_start, hunk.old_start) if reverse else (hunk.old_start, hunk.new_start)
        )
        index = _first_index(from_start, len(taken))
        if index < position:
            raise PatchError(f"hunk {hunk.number} overlaps or precedes the hunk before it")
        if source[index : index + len(taken)] != taken:
            raise PatchError(f"hunk {hunk.number} does not match at line {from_start}")
        result += source[position:index]
        side = "old" if reverse else "new"
        if len(result) != _first_index(to_start, len(given)):
            raise PatchError(
                f"hunk {hunk.number} starts at line {to_start} of the {side} file, but the "
                f"hunks before it put it at line {len(result) + 1}"
            )
        result += given
        position = index + len(taken)
    result += source[position:]
    return b"".join(result)


def recorded_sha256() -> str:
    """The checksum in CHECKSUM_FILE; raise PatchError if the file is not one such line."""
    line = CHECKSUM_LINE.match(CHECKSUM_FILE.read_text())
    if not line:
        raise PatchError(f"{CHECKSUM_FILE} is not one `<sha256>  core/util/cursor.js` line")
    return line.group(1)


def original_of(overlay: bytes, patch: bytes, sha256: str) -> bytes:
    """The file OVERLAY was made from (PATCH taken back out); it must have checksum SHA256."""
    hunks = parse_patch(patch)
    original = apply_patch(overlay, hunks, reverse=True)
    actual = hashlib.sha256(original).hexdigest()
    if actual != sha256:
        raise PatchError(
            f"the overlay without the patch (sha256 {actual}) is not the recorded original "
            f"(sha256 {sha256}): the overlay was changed without the patch"
        )
    if apply_patch(original, hunks) != overlay:
        raise PatchError("the patch does not turn the original back into the overlay")
    return original


def check_image_file(image_file: Path) -> list[str]:
    """What is wrong with IMAGE_FILE (the image's cursor.js) and the overlay; [] if nothing."""
    try:
        original = image_file.read_bytes()
    except OSError as err:
        return [f"cannot read the image's cursor.js: {err}"]
    try:
        recorded = recorded_sha256()
        actual = hashlib.sha256(original).hexdigest()
        if actual != recorded:
            changed = (
                f"the image's noVNC core/util/cursor.js changed (sha256 {actual}, recorded "
                f"{recorded} in {CHECKSUM_FILE.relative_to(REPO_ROOT)}): re-apply "
                f"{PATCH_FILE.relative_to(REPO_ROOT)} to it, as config/cursors/README.md says"
            )
            return [changed]
        patched = apply_patch(original, parse_patch(PATCH_FILE.read_bytes()))
    except (OSError, PatchError) as err:
        return [str(err)]
    if patched != OVERLAY.read_bytes():
        mismatch = (
            f"{OVERLAY.relative_to(REPO_ROOT)} is not the image's cursor.js plus "
            f"{PATCH_FILE.relative_to(REPO_ROOT)}"
        )
        return [mismatch]
    return []


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} IMAGE_CURSOR_JS", file=sys.stderr)
        return 2
    problems = check_image_file(Path(argv[1]))
    for problem in problems:
        print(f"FAIL  {problem}", file=sys.stderr)
    if problems:
        return 1
    print(
        f"ok    the image's noVNC cursor.js is the recorded one (sha256 {recorded_sha256()}), "
        f"and {OVERLAY.relative_to(REPO_ROOT)} is it plus {PATCH_FILE.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
