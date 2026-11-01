#!/usr/bin/env python3
"""Check that each overlay is the firefox image's file plus its patch.

The firefox service mounts patched copies of some of its image's files over the image's own
("overlays"): config/novnc/cursor.js over /opt/noVNC/core/util/cursor.js, config/novnc/ui.js
over /opt/noVNC/app/ui.js, and config/firefox-services/kill over /etc/services.d/app/kill. A new
image's version of any of them would be hidden, with its fixes. For each overlay NAME, in its
repo directory, NAME.upstream.sha256 records the checksum of the image file the overlay was made
from, and NAME.patch the change (`diff -u` output).

Given IMAGE_ROOT, a directory holding the image's files at their absolute paths (for example
IMAGE_ROOT/opt/noVNC/app/ui.js, copied out of the image with `docker create` and `docker cp`),
this exits 0 if each has the recorded checksum and its patch turns it into the overlay;
otherwise it says which and exits 1. A patch is applied strictly: every hunk must match exactly
where it says, with no offset and no fuzz (unlike `patch`). With --paths, it prints the image
path of each overlay, one per line, for the scripts that copy those files out of the image.
The unit tests (tests/test_image_overlays.py) check the overlays without the image's files, by
taking each patch back out of its overlay. config/cursors/README.md says how to update the
three files of an overlay.

Usage: python3 -I tests/image_overlays.py IMAGE_ROOT
       python3 -I tests/image_overlays.py --paths
"""

import hashlib
import re
import sys
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parent.parent
README = "config/cursors/README.md"
HUNK_HEADER = re.compile(rb"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?\n\Z")


class PatchError(Exception):
    """The patch cannot be read, or does not apply, or gives the wrong file."""


class Overlay(NamedTuple):
    """REPO_DIR/NAME (repo-relative), mounted over IMAGE_DIR/IMAGE_PATH in the image.

    IMAGE_DIR is an absolute directory of the image; IMAGE_PATH is relative to it, and is the
    path the checksum file and the patch's headers name.
    """

    repo_dir: str
    name: str
    image_dir: str
    image_path: str

    @property
    def path(self) -> Path:
        return REPO_ROOT / self.repo_dir / self.name

    @property
    def patch_file(self) -> Path:
        return REPO_ROOT / self.repo_dir / f"{self.name}.patch"

    @property
    def checksum_file(self) -> Path:
        return REPO_ROOT / self.repo_dir / f"{self.name}.upstream.sha256"

    @property
    def target(self) -> str:
        """The image file's absolute path, which the overlay is mounted over."""
        return f"{self.image_dir}/{self.image_path}"


OVERLAYS = (
    Overlay("config/novnc", "cursor.js", "/opt/noVNC", "core/util/cursor.js"),
    Overlay("config/novnc", "ui.js", "/opt/noVNC", "app/ui.js"),
    Overlay("config/firefox-services", "kill", "/etc/services.d/app", "kill"),
)


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


def recorded_sha256(overlay: Overlay) -> str:
    """The checksum in OVERLAY's checksum file; raise PatchError if it is not one such line."""
    # One `sha256sum` line: the digest, two spaces, the file's path under its image directory.
    pattern = re.compile(rf"\A([0-9a-f]{{64}})  {re.escape(overlay.image_path)}\n\Z")
    line = pattern.match(overlay.checksum_file.read_text())
    if not line:
        raise PatchError(
            f"{overlay.checksum_file} is not one `<sha256>  {overlay.image_path}` line"
        )
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


def copied_path(image_root: Path, overlay: Overlay) -> Path:
    """Where IMAGE_ROOT holds the image's file that OVERLAY is mounted over."""
    return image_root / overlay.target.lstrip("/")


def check_image_file(overlay: Overlay, image_file: Path) -> list[str]:
    """What is wrong with IMAGE_FILE (the image's file) and OVERLAY; [] if nothing."""
    try:
        original = image_file.read_bytes()
    except OSError as err:
        return [f"cannot read the image's {overlay.target}: {err}"]
    patch_file = overlay.patch_file.relative_to(REPO_ROOT)
    try:
        recorded = recorded_sha256(overlay)
        actual = hashlib.sha256(original).hexdigest()
        if actual != recorded:
            changed = (
                f"the image's {overlay.target} changed (sha256 {actual}, recorded "
                f"{recorded} in {overlay.checksum_file.relative_to(REPO_ROOT)}): re-apply "
                f"{patch_file} to it, as {README} says"
            )
            return [changed]
        patched = apply_patch(original, parse_patch(overlay.patch_file.read_bytes()))
    except (OSError, PatchError) as err:
        return [f"{overlay.repo_dir}/{overlay.name}: {err}"]
    if patched != overlay.path.read_bytes():
        mismatch = (
            f"{overlay.path.relative_to(REPO_ROOT)} is not the image's {overlay.target} "
            f"plus {patch_file}"
        )
        return [mismatch]
    return []


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} IMAGE_ROOT | --paths", file=sys.stderr)
        return 2
    if argv[1] == "--paths":
        for overlay in OVERLAYS:
            print(overlay.target)
        return 0
    image_root = Path(argv[1])
    failed = False
    for overlay in OVERLAYS:
        problems = check_image_file(overlay, copied_path(image_root, overlay))
        for problem in problems:
            print(f"FAIL  {problem}", file=sys.stderr)
        if problems:
            failed = True
            continue
        print(
            f"ok    the image's {overlay.target} is the recorded one (sha256 "
            f"{recorded_sha256(overlay)}), and {overlay.path.relative_to(REPO_ROOT)} is it plus "
            f"{overlay.patch_file.relative_to(REPO_ROOT)}"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
