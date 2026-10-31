#!/usr/bin/env bash
# Browser tests of the web UI's client side: the patched noVNC Cursor class,
# and the audio player.
#
# Copies noVNC's core/ and the audio player (app/pcm-player.min.js and the
# app/unmute.min.js it imports) from the firefox service's image, overlays the
# repo's config/novnc files the service mounts, serves them with harness.html,
# the generated cases.js and audio-harness.html on 127.0.0.1, and loads each
# harness in headless Chrome and headless Firefox. The cursor harness's result is
# read with --dump-dom in Chrome; everything else is driven by page-result.mjs
# (browser.mjs: the DevTools Protocol for Chrome, WebDriver BiDi for Firefox).
# The audio harness runs in real time and needs a real click. Each run uses a
# throwaway profile.
#
# Usage: tests/browser/run.sh   (needs docker, python3, node, and Google
#        Chrome and/or Firefox in /Applications)

set -euo pipefail

BROWSER_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$BROWSER_DIR/../.." && pwd)
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FIREFOX="/Applications/Firefox.app/Contents/MacOS/firefox"
WORK=$(mktemp -d)
SERVER_PID=""
CONTAINER=""

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -n "$CONTAINER" ]] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

IMAGE=$(docker compose -f "$REPO/docker-compose.yml" config --format json \
    | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["firefox"]["image"])')
echo "noVNC from: $IMAGE"

mkdir -p "$WORK/site/core/util" "$WORK/profiles"
CONTAINER=$(docker create "$IMAGE")
docker cp -q "$CONTAINER:/opt/noVNC/core" "$WORK/site/"
docker cp -q "$CONTAINER:/opt/noVNC/vendor" "$WORK/site/"
mkdir -p "$WORK/site/app"
for file in pcm-player.min.js unmute.min.js; do
    docker cp -q "$CONTAINER:/opt/noVNC/app/$file" "$WORK/site/app/"
done
# The overlay below replaces the image's cursor.js, which would hide any change a new image
# made to it: first check that the image's file is still the one config/novnc/cursor.js.patch
# was made from, and that the overlay is it plus the patch (config/cursors/README.md).
python3 -I "$REPO/tests/novnc_cursor_patch.py" "$WORK/site/core/util/cursor.js"
for file in cursor.js cursor-keyword.js core-glyphs.js; do
    cp "$REPO/config/novnc/$file" "$WORK/site/core/util/$file"
done
cp "$BROWSER_DIR/harness.html" "$BROWSER_DIR/audio-harness.html" "$WORK/site/"
node "$BROWSER_DIR/make-cases.mjs" "$WORK/site/cases.js"
# The harness reports how many cases it checked; a run passes only if that is
# every generated case and none failed.
EXPECTED=$(node -e '
    const { pathToFileURL } = require("node:url");
    import(pathToFileURL(process.argv[1])).then(m => console.log(m.default.length));
' "$WORK/site/cases.js")
if [[ ! "$EXPECTED" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL  no cases generated (count: '$EXPECTED')"
    exit 1
fi

# The audio harness's cases (audio-harness.html), and the title at which it waits
# for a click.
AUDIO_CASES=6
AUDIO_CLICK_TITLE="audio harness: click to start"

# result_ok RESULT COUNT: exits 0 if the harness result (JSON) checked all COUNT
# cases with none failed.
result_ok() {
    python3 -I -c '
import json, sys
try:
    result = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
ok = (
    isinstance(result, dict)
    and type(result.get("total")) is int
    and type(result.get("failed")) is int
    and result["total"] == int(sys.argv[2])
    and result["failed"] == 0
)
sys.exit(0 if ok else 1)
' "$1" "$2"
}

free_port() {
    python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

PORT=$(free_port)
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
URL="http://127.0.0.1:$PORT/harness.html"
AUDIO_URL="http://127.0.0.1:$PORT/audio-harness.html"
for _ in $(seq 1 50); do
    curl -sf -o /dev/null "$URL" && break
    sleep 0.1
done

failures=0
browsers=0

# report LABEL RESULT COUNT: prints ok or FAIL for a harness RESULT of COUNT cases.
report() {
    if result_ok "$2" "$3"; then
        echo "ok    $1: $2"
    else
        echo "FAIL  $1 (expected $3 cases, none failed): ${2:-no result in page}"
        failures=$((failures + 1))
    fi
}

if [[ -x "$CHROME" ]]; then
    browsers=$((browsers + 1))
    version=$("$CHROME" --version | sed 's/ *$//')
    result=$("$CHROME" --headless=new --disable-gpu --no-first-run \
        --user-data-dir="$WORK/profiles/chrome" --virtual-time-budget=10000 \
        --dump-dom "$URL" 2>/dev/null | sed -n 's:.*<pre id="result">\(.*\)</pre>.*:\1:p')
    report "$version cursor" "$result" "$EXPECTED"
    result=$(node "$BROWSER_DIR/page-result.mjs" chrome "$CHROME" "$WORK/profiles/chrome-audio" \
        "$(free_port)" "$AUDIO_URL" "$AUDIO_CLICK_TITLE") || true
    report "$version audio" "$result" "$AUDIO_CASES"
fi

if [[ -x "$FIREFOX" ]]; then
    browsers=$((browsers + 1))
    version=$("$FIREFOX" --version)
    mkdir -p "$WORK/profiles/firefox" "$WORK/profiles/firefox-audio"
    result=$(node "$BROWSER_DIR/page-result.mjs" firefox "$FIREFOX" "$WORK/profiles/firefox" \
        "$(free_port)" "$URL") || true
    report "$version cursor" "$result" "$EXPECTED"
    result=$(node "$BROWSER_DIR/page-result.mjs" firefox "$FIREFOX" \
        "$WORK/profiles/firefox-audio" "$(free_port)" "$AUDIO_URL" "$AUDIO_CLICK_TITLE") || true
    report "$version audio" "$result" "$AUDIO_CASES"
fi

if ((browsers == 0)); then
    echo "FAIL  no browser found (looked for $CHROME and $FIREFOX)"
    exit 1
fi
if ((failures > 0)); then
    exit 1
fi
echo "browser checks passed in $browsers browser(s)"
