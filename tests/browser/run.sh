#!/usr/bin/env bash
# Browser test of the patched noVNC Cursor class, client side.
#
# Copies noVNC's core/ from the firefox service's image, overlays the repo's
# config/novnc files the service mounts, serves it with harness.html and the
# generated cases.js on 127.0.0.1, and loads it in headless Chrome (result read
# with --dump-dom) and headless Firefox (result read over WebDriver BiDi by
# firefox-bidi.mjs). Each browser uses a throwaway profile.
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
for file in cursor.js cursor-keyword.js core-glyphs.js; do
    cp "$REPO/config/novnc/$file" "$WORK/site/core/util/$file"
done
cp "$BROWSER_DIR/harness.html" "$WORK/site/"
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

# Exits 0 if the harness result (JSON) checked all EXPECTED cases with none failed.
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
' "$1" "$EXPECTED"
}

free_port() {
    python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

PORT=$(free_port)
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
URL="http://127.0.0.1:$PORT/harness.html"
for _ in $(seq 1 50); do
    curl -sf -o /dev/null "$URL" && break
    sleep 0.1
done

failures=0
browsers=0

if [[ -x "$CHROME" ]]; then
    browsers=$((browsers + 1))
    version=$("$CHROME" --version)
    result=$("$CHROME" --headless=new --disable-gpu --no-first-run \
        --user-data-dir="$WORK/profiles/chrome" --virtual-time-budget=10000 \
        --dump-dom "$URL" 2>/dev/null | sed -n 's:.*<pre id="result">\(.*\)</pre>.*:\1:p')
    if result_ok "$result"; then
        echo "ok    $version: $result"
    else
        echo "FAIL  $version (expected $EXPECTED cases, none failed): ${result:-no result in page}"
        failures=$((failures + 1))
    fi
fi

if [[ -x "$FIREFOX" ]]; then
    browsers=$((browsers + 1))
    version=$("$FIREFOX" --version)
    mkdir -p "$WORK/profiles/firefox"
    bidi_port=$(free_port)
    result=$(node "$BROWSER_DIR/firefox-bidi.mjs" "$FIREFOX" "$WORK/profiles/firefox" \
        "$bidi_port" "$URL") || true
    if result_ok "$result"; then
        echo "ok    $version: $result"
    else
        echo "FAIL  $version (expected $EXPECTED cases, none failed): ${result:-no result in page}"
        failures=$((failures + 1))
    fi
fi

if ((browsers == 0)); then
    echo "FAIL  no browser found (looked for $CHROME and $FIREFOX)"
    exit 1
fi
if ((failures > 0)); then
    exit 1
fi
echo "browser checks passed in $browsers browser(s)"
