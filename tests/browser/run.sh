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
# Then the whole audio path, in each browser: a throwaway container from the
# image, started as tests/e2e/run.sh starts them (the service's settings and
# hardening, WEB_AUDIO included, and no network), shows tests/e2e/audio-page.html;
# tunnel.py makes its web UI reachable on 127.0.0.1, and web-ui-audio.mjs loads
# it and checks, at the web UI's own audio output, the first-use and the
# returning-user paths (see that file).
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
WEB_CONTAINER="web-ui-audio-$$"
TUNNEL_PID=""

stop_web_ui() {
    [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    docker rm -f "$WEB_CONTAINER" >/dev/null 2>&1 || true
}

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -n "$CONTAINER" ]] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    stop_web_ui
    rm -rf "$WORK"
}
trap cleanup EXIT

docker compose -f "$REPO/docker-compose.yml" config --format json >"$WORK/compose.json"
python3 -I "$REPO/tests/e2e/service_args.py" <"$WORK/compose.json" >"$WORK/service-args"
IMAGE=$(head -n 1 "$WORK/service-args")
SERVICE_ARGS=()
while IFS= read -r arg; do
    SERVICE_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args")
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

# web-ui-audio.mjs's cases.
WEB_UI_CASES=10

# report LABEL RESULT COUNT: prints ok or FAIL for a harness RESULT of COUNT cases.
report() {
    if result_ok "$2" "$3"; then
        echo "ok    $1: $2"
    else
        echo "FAIL  $1 (expected $3 cases, none failed): ${2:-no result in page}"
        failures=$((failures + 1))
    fi
}

in_x() { docker exec -u 1000 -e DISPLAY=:0 "$WEB_CONTAINER" "$@"; }

# Starts the container on audio-page.html and the tunnel to its web UI; sets
# WEB_UI_URL. Returns 1 (and prints why) if either does not come up.
start_web_ui() {
    local window="" port=""
    stop_web_ui
    docker run -d --rm --name "$WEB_CONTAINER" --network none --shm-size 1g \
        "${SERVICE_ARGS[@]}" \
        -e FF_OPEN_URL=file:///e2e/audio-page.html \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        -v "$REPO/tests/e2e:/e2e:ro" \
        "$IMAGE" >/dev/null
    for _ in $(seq 1 90); do
        window=$(in_x xdotool search --classname Navigator 2>/dev/null | head -n 1) || true
        if [[ -n "$window" ]] &&
            [[ "$(in_x xdotool getwindowname "$window" 2>/dev/null)" == *"e2e audio page"* ]]; then
            break
        fi
        window=""
        sleep 1
    done
    if [[ -z "$window" ]]; then
        echo "Firefox never showed audio-page.html"
        return 1
    fi
    python3 -I "$BROWSER_DIR/tunnel.py" 0 docker exec -i "$WEB_CONTAINER" nc -N 127.0.0.1 5800 \
        >"$WORK/tunnel.out" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 50); do
        port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$WORK/tunnel.out")
        [[ -n "$port" ]] && break
        sleep 0.1
    done
    if [[ -z "$port" ]]; then
        echo "tunnel.py did not start: $(cat "$WORK/tunnel.out")"
        return 1
    fi
    WEB_UI_URL="http://127.0.0.1:$port/"
}

# web_ui_audio KIND BINARY LABEL: the whole audio path in browser KIND.
web_ui_audio() {
    local result
    # Not in $(...): the tunnel and WEB_UI_URL must outlive the call.
    if ! start_web_ui >"$WORK/start.out"; then
        report "$3 web UI" "$(cat "$WORK/start.out")" "$WEB_UI_CASES"
        stop_web_ui
        return
    fi
    result=$(node "$BROWSER_DIR/web-ui-audio.mjs" "$1" "$2" "$WORK/profiles/$1-web-ui" \
        "$(free_port)" "$WEB_UI_URL") || true
    report "$3 web UI" "$result" "$WEB_UI_CASES"
    stop_web_ui
}

# The firefox service streams its audio (docker-compose.yml); the container below follows it.
if [[ " ${SERVICE_ARGS[*]} " != *" WEB_AUDIO=1 "* ]]; then
    echo "FAIL  the firefox service does not set WEB_AUDIO=1"
    failures=$((failures + 1))
fi

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
    web_ui_audio chrome "$CHROME" "$version"
fi

if [[ -x "$FIREFOX" ]]; then
    browsers=$((browsers + 1))
    version=$("$FIREFOX" --version)
    mkdir -p "$WORK/profiles/firefox" "$WORK/profiles/firefox-audio" "$WORK/profiles/firefox-web-ui"
    result=$(node "$BROWSER_DIR/page-result.mjs" firefox "$FIREFOX" "$WORK/profiles/firefox" \
        "$(free_port)" "$URL") || true
    report "$version cursor" "$result" "$EXPECTED"
    result=$(node "$BROWSER_DIR/page-result.mjs" firefox "$FIREFOX" \
        "$WORK/profiles/firefox-audio" "$(free_port)" "$AUDIO_URL" "$AUDIO_CLICK_TITLE") || true
    report "$version audio" "$result" "$AUDIO_CASES"
    web_ui_audio firefox "$FIREFOX" "$version"
fi

if ((browsers == 0)); then
    echo "FAIL  no browser found (looked for $CHROME and $FIREFOX)"
    exit 1
fi
if ((failures > 0)); then
    exit 1
fi
echo "browser checks passed in $browsers browser(s)"
