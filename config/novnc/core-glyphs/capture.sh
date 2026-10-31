#!/usr/bin/env bash
# Regenerates config/novnc/core-glyphs.js: the X core cursor font glyphs that
# Openbox uses, exactly as the firefox service's VNC server sends them, each
# mapped to the CSS cursor keyword the patched noVNC shows instead.
#
# Openbox here is built without Xcursor support, so its cursors (window
# move/resize, title bars and edges of the windows it decorates, the root
# window) are 1-bit core glyphs that the native-css theme cannot replace.
#
# Steps: build fontgrab.c against the image's Alpine release (in a separate
# build container, which needs network for apk), start a throwaway container
# from the image with no network, grab the pointer with each glyph, and read
# the cursor with tests/e2e/rfb_cursor_probe.py. Run again after changing the
# image tag; `git diff` then shows whether any glyph changed.
#
# Usage: config/novnc/core-glyphs/capture.sh   (needs docker and python3)

set -euo pipefail

GLYPH_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$GLYPH_DIR/../../.." && pwd)
CONTAINER="core-glyph-capture-$$"
# Runs tests/e2e/rfb_cursor_probe.py. Pinned by tag and multi-arch index digest
# (Python 3.13.18 on Alpine 3.24; `docker buildx imagetools inspect` shows the digest).
PROBE_IMAGE=python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
WORK=$(mktemp -d)

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Openbox cursor -> X cursor font glyph (X11/cursorfont.h) -> CSS keyword.
# Openbox's load_cursor() list: POINTER and BUSYPOINTER use left_ptr, BUSY
# uses watch, MOVE uses fleur, and the eight resize directions use the side
# and corner glyphs. Openbox resizes an edge or corner both ways, so they map
# to the two-way keywords: macOS draws the one-way ones (n-resize and so on)
# with the opposite arrowhead grayed out.
GLYPHS=(
    "left_ptr 68 default"
    "watch 150 wait"
    "fleur 52 move"
    "top_side 138 ns-resize"
    "top_right_corner 136 nesw-resize"
    "right_side 96 ew-resize"
    "bottom_right_corner 14 nwse-resize"
    "bottom_side 16 ns-resize"
    "bottom_left_corner 12 nesw-resize"
    "left_side 70 ew-resize"
    "top_left_corner 134 nwse-resize"
)

IMAGE=$(docker compose -f "$REPO/docker-compose.yml" config --format json \
    | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["firefox"]["image"])')
ALPINE=$(docker run --rm --network none --entrypoint sh "$IMAGE" \
    -c '. /etc/os-release && echo "${VERSION_ID%.*}"')
echo "image: $IMAGE (Alpine $ALPINE)"
echo "$IMAGE" > "$WORK/image.txt"

echo "building fontgrab..."
docker run --rm -v "$GLYPH_DIR/fontgrab.c:/src/fontgrab.c:ro" -v "$WORK:/out" \
    "alpine:$ALPINE" sh -c '
        apk add -q --no-cache build-base libx11-dev >/dev/null &&
        cc -O2 -Wall -Wextra -Werror -o /out/fontgrab /src/fontgrab.c -lX11'

docker run -d --rm --name "$CONTAINER" --network none \
    -v "$WORK/fontgrab:/capture/fontgrab:ro" "$IMAGE" >/dev/null

# The image runs X as USER_ID, which defaults to 1000.
in_x() { docker exec -u 1000 -e DISPLAY=:0 -e XCURSOR_CORE=1 "$CONTAINER" "$@"; }

# Captures taken while the desktop is still starting can come back empty, so
# wait for Firefox's window and let it settle first.
echo "waiting for the Firefox window..."
for _ in $(seq 1 90); do
    if in_x xdotool search --classname Navigator >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
in_x xdotool search --classname Navigator >/dev/null
sleep 5

for entry in "${GLYPHS[@]}"; do
    read -r name index keyword <<<"$entry"
    docker exec -d -u 1000 -e DISPLAY=:0 -e XCURSOR_CORE=1 "$CONTAINER" \
        sh -c "/capture/fontgrab $index 30 2>/tmp/fontgrab.log"
    sleep 1
    docker run --rm --network "container:$CONTAINER" \
        -v "$REPO/tests/e2e:/e2e:ro" -v "$WORK:/out" "$PROBE_IMAGE" \
        python -I /e2e/rfb_cursor_probe.py 127.0.0.1 5900 960 540 "/out/$name" \
        > "$WORK/$name.json"
    # The capture only counts if fontgrab still held its grab after the probe.
    # (BusyBox pkill -x does not match fontgrab by name, so match its command line.)
    if ! in_x pkill -f '^/capture/fontgrab '; then
        echo "fontgrab $name ($index) was not running: $(in_x cat /tmp/fontgrab.log)" >&2
        exit 1
    fi
    sleep 0.5
    echo "$name $index $keyword" >> "$WORK/glyphs.txt"
    echo "  $name: $(cat "$WORK/$name.json")"
done

python3 -I "$GLYPH_DIR/make_table.py" "$WORK" "$REPO/config/novnc/core-glyphs.js"
