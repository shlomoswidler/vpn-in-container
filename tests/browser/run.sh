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
# throwaway profile, and the browsers can reach only loopback: everything else
# goes to a proxy at a closed port (browser.mjs's CLOSED_PROXY), so their own
# background requests never leave this computer.
#
# Then the whole audio path, in each browser: throwaway containers from the
# image, started as tests/e2e/run.sh starts them (the service's settings and
# hardening, WEB_AUDIO included, and no network), show tests/e2e/audio-page.html;
# tunnel.py makes each one's web UI reachable on 127.0.0.1, and web-ui-audio.mjs
# loads it and checks, at the web UI's own audio output, the first-use and the
# returning-user paths, and what a restart of the container (which the same tab
# reconnects to) does to sound that was on, and to sound that was muted (see
# that file). The sound-on restart and the muted restart are its two parts, each
# with its own container, tab and profile, run at the same time; the muted part's
# waits for sound to stay off are sized from the other part's measured times,
# which it reads from a file here. Their results print as one.
#
# And switching windows from the web UI, in each browser: a throwaway container
# as above but with private-only browsing off (FIREFOX_PRIVATE_BROWSING=false,
# whatever .env sets) and showing tests/e2e/blank-page.html, so it can have a
# normal and a private window; web-ui-windows.mjs opens a private window in it
# and checks that Ctrl+` typed in the web UI shows the other window (see that
# file).
#
# Every check runs at the same time as the others, as a job of its own (each in
# a process group of its own, so that cleanup can stop what it started): the
# local harnesses, the two audio parts and the windows check, in each browser,
# each with its own container (web-ui-PID-KIND-PART), tunnel, port and
# profiles. The containers start first, and the local harnesses run while they
# boot. The results print in order once all are done.
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
# Each job's web UI container is web-ui-PID-KIND-PART (web_ui_job sets it).
WEB_CONTAINER=""
TUNNEL_PID=""
# The jobs (start_job): each one's name, and its process id, which is also its
# process group's.
JOB_NAMES=()
JOB_PIDS=()
# The web UI containers the jobs may start.
WEB_CONTAINERS=()
# As in tests/e2e/run.sh: the test containers have no network, so a resolver
# that refuses at once keeps Firefox from waiting out DNS timeouts as it quits
# (each `docker restart` below quits it).
NO_DNS_ARGS=(--dns 127.0.0.1 --dns-opt timeout:1 --dns-opt attempts:1)

stop_web_ui() {
    [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    [[ -z "$WEB_CONTAINER" ]] || docker rm -f -v "$WEB_CONTAINER" >/dev/null 2>&1 || true
}

# stop_job PID: stops every process in job PID's process group (its node, the
# browser that started, tunnel.py), and waits up to 5 s for them to end.
stop_job() {
    kill -TERM -- "-$1" 2>/dev/null || return 0
    for _ in $(seq 1 50); do
        kill -0 -- "-$1" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL -- "-$1" 2>/dev/null || true
}

cleanup() {
    local pid
    for pid in ${JOB_PIDS[@]+"${JOB_PIDS[@]}"}; do
        stop_job "$pid"
    done
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -n "$CONTAINER" ]] && docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
    if ((${#WEB_CONTAINERS[@]} > 0)); then
        docker rm -f -v "${WEB_CONTAINERS[@]}" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker compose -f "$REPO/docker-compose.yml" config --format json >"$WORK/compose.json"
python3 -I "$REPO/tests/e2e/service_args.py" <"$WORK/compose.json" >"$WORK/service-args"
IMAGE=$(head -n 1 "$WORK/service-args")
SERVICE_ARGS=()
while IFS= read -r arg; do
    SERVICE_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args")
# The same with private-only browsing off (the shell's value wins over .env's).
FIREFOX_PRIVATE_BROWSING=false docker compose -f "$REPO/docker-compose.yml" config \
    --format json >"$WORK/compose-off.json"
python3 -I "$REPO/tests/e2e/service_args.py" <"$WORK/compose-off.json" >"$WORK/service-args-off"
OFF_ARGS=()
while IFS= read -r arg; do
    OFF_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args-off")
echo "noVNC from: $IMAGE"

failures=0

# The firefox service streams its audio (docker-compose.yml); the containers below follow it.
if [[ " ${SERVICE_ARGS[*]} " != *" WEB_AUDIO=1 "* ]]; then
    echo "FAIL  the firefox service does not set WEB_AUDIO=1"
    failures=$((failures + 1))
fi

# free_ports N: N different free ports on 127.0.0.1, one per line.
free_ports() {
    python3 -I -c '
import socket, sys
sockets = [socket.socket() for _ in range(int(sys.argv[1]))]
for s in sockets:
    s.bind(("127.0.0.1", 0))
print("\n".join(str(s.getsockname()[1]) for s in sockets))
' "$1"
}

# The browsers found, and a port for each job's browser (5 per browser) and the server.
kinds=()
binaries=()
for kind in chrome firefox; do
    if [[ "$kind" == chrome ]]; then binary=$CHROME; else binary=$FIREFOX; fi
    [[ -x "$binary" ]] || continue
    kinds+=("$kind")
    binaries+=("$binary")
done
PORTS=()
while IFS= read -r port; do
    PORTS+=("$port")
done < <(free_ports $((1 + 5 * ${#kinds[@]})))
mkdir -p "$WORK/profiles" "$WORK/results" "$WORK/logs"

# start_job NAME FUNCTION ARGS...: runs FUNCTION ARGS... in the background, in a
# subshell in a process group of its own; its output in $WORK/logs/NAME.
start_job() {
    local name=$1
    shift
    set -m
    ("$@") >"$WORK/logs/$name" 2>&1 </dev/null &
    JOB_PIDS+=("$!")
    set +m
    JOB_NAMES+=("$name")
}

in_x() { docker exec -u 1000 -e DISPLAY=:0 "$WEB_CONTAINER" "$@"; }

# start_web_ui PAGE TITLE ARGS...: starts the container with the `docker run`
# ARGS on tests/e2e/PAGE, waits for Firefox to show it (a window title with
# TITLE), and starts the tunnel to its web UI; sets WEB_UI_URL. Returns 1 (and
# prints why) if either does not come up.
start_web_ui() {
    local page=$1 title=$2 window="" port=""
    shift 2
    stop_web_ui
    if ! docker run -d --rm --name "$WEB_CONTAINER" --network none "${NO_DNS_ARGS[@]}" \
        --shm-size 1g "$@" \
        -e "FF_OPEN_URL=file:///e2e/$page" \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        -v "$REPO/tests/e2e:/e2e:ro" \
        "$IMAGE" >/dev/null; then
        echo "docker run $WEB_CONTAINER failed"
        return 1
    fi
    # Every 0.25 s, for up to 90 s.
    for _ in $(seq 1 360); do
        window=$(in_x xdotool search --classname Navigator 2>/dev/null | head -n 1) || true
        if [[ -n "$window" ]] &&
            [[ "$(in_x xdotool getwindowname "$window" 2>/dev/null)" == *"$title"* ]]; then
            break
        fi
        window=""
        sleep 0.25
    done
    if [[ -z "$window" ]]; then
        echo "Firefox never showed $page"
        return 1
    fi
    python3 -I "$BROWSER_DIR/tunnel.py" 0 docker exec -i "$WEB_CONTAINER" nc -N 127.0.0.1 5800 \
        >"$WORK/tunnel-$WEB_CONTAINER.out" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 50); do
        port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$WORK/tunnel-$WEB_CONTAINER.out")
        [[ -n "$port" ]] && break
        sleep 0.1
    done
    if [[ -z "$port" ]]; then
        echo "tunnel.py did not start: $(cat "$WORK/tunnel-$WEB_CONTAINER.out")"
        return 1
    fi
    WEB_UI_URL="http://127.0.0.1:$port/"
}

# The file in which web-ui-audio.mjs's reconnect part, in browser KIND, leaves its
# measured times for the muted part.
timings_file() { echo "$WORK/$1-timings.json"; }

# web_ui_job KIND BINARY PORT PART: one web UI check in browser KIND, with the
# DevTools or WebDriver BiDi port PORT, in a container of its own: PART reconnect
# or muted is that part of web-ui-audio.mjs, windows is web-ui-windows.mjs. Its
# result in $WORK/results/KIND-PART. Run as a job.
web_ui_job() {
    local kind=$1 binary=$2 port=$3 part=$4 result timings
    local out="$WORK/results/$kind-$part" start="$WORK/start-$kind-$part.out"
    timings=$(timings_file "$kind")
    WEB_CONTAINER="web-ui-$$-$kind-$part"
    trap stop_web_ui EXIT
    # Not in $(...): the tunnel and WEB_UI_URL must outlive the call.
    if [[ "$part" == windows ]]; then
        start_web_ui blank-page.html "e2e blank page" "${OFF_ARGS[@]}" >"$start" || true
    else
        start_web_ui audio-page.html "e2e audio page" "${SERVICE_ARGS[@]}" >"$start" || true
    fi
    if [[ -z "${WEB_UI_URL:-}" ]]; then
        cp "$start" "$out"
    elif [[ "$part" == windows ]]; then
        result=$(node "$BROWSER_DIR/web-ui-windows.mjs" "$kind" "$binary" \
            "$WORK/profiles/$kind-windows" "$port" "$WEB_UI_URL" "$WEB_CONTAINER") || true
        printf '%s\n' "$result" >"$out"
    else
        result=$(node "$BROWSER_DIR/web-ui-audio.mjs" "$kind" "$binary" \
            "$WORK/profiles/$kind-$part" "$port" "$WEB_UI_URL" "$WEB_CONTAINER" "$part" \
            "$timings") || true
        printf '%s\n' "$result" >"$out"
    fi
    # The muted part waits for these: if the reconnect part ended without them, say so.
    if [[ "$part" == reconnect && ! -e "$timings" ]]; then
        echo '{"error": "the reconnect part ended before it had them"}' >"$timings.tmp"
        mv "$timings.tmp" "$timings"
    fi
    stop_web_ui
}

# local_harnesses KIND BINARY PORT PORT2: the cursor and the audio harness in
# browser KIND (Firefox's cursor harness on PORT, the audio harness on PORT2);
# their results in $WORK/results/KIND-cursor and KIND-audio. Run as a job.
local_harnesses() {
    local kind=$1 binary=$2 result
    if [[ "$kind" == chrome ]]; then
        # The proxy is browser.mjs's CLOSED_PROXY: Chrome reaches only loopback.
        result=$("$binary" --headless=new --disable-gpu --no-first-run \
            --user-data-dir="$WORK/profiles/chrome" --virtual-time-budget=10000 \
            --proxy-server=127.0.0.1:9 \
            --dump-dom "$URL" 2>/dev/null | sed -n 's:.*<pre id="result">\(.*\)</pre>.*:\1:p')
    else
        result=$(node "$BROWSER_DIR/page-result.mjs" firefox "$binary" "$WORK/profiles/firefox" \
            "$3" "$URL") || true
    fi
    printf '%s\n' "$result" >"$WORK/results/$kind-cursor"
    result=$(node "$BROWSER_DIR/page-result.mjs" "$kind" "$binary" \
        "$WORK/profiles/$kind-audio" "$4" "$AUDIO_URL" "$AUDIO_CLICK_TITLE") || true
    printf '%s\n' "$result" >"$WORK/results/$kind-audio"
}

# The web UI containers first: they take the longest to come up.
for i in ${kinds[@]+"${!kinds[@]}"}; do
    kind=${kinds[$i]}
    mkdir -p "$WORK/profiles/$kind-reconnect" "$WORK/profiles/$kind-muted" \
        "$WORK/profiles/$kind-windows"
    for part in reconnect muted windows; do
        WEB_CONTAINERS+=("web-ui-$$-$kind-$part")
    done
    start_job "$kind-reconnect" web_ui_job "$kind" "${binaries[$i]}" "${PORTS[$((1 + 5 * i))]}" \
        reconnect
    start_job "$kind-muted" web_ui_job "$kind" "${binaries[$i]}" "${PORTS[$((2 + 5 * i))]}" muted
    start_job "$kind-windows" web_ui_job "$kind" "${binaries[$i]}" "${PORTS[$((3 + 5 * i))]}" \
        windows
done

mkdir -p "$WORK/site/core/util"
CONTAINER=$(docker create "$IMAGE")
docker cp -q "$CONTAINER:/opt/noVNC/core" "$WORK/site/"
docker cp -q "$CONTAINER:/opt/noVNC/vendor" "$WORK/site/"
mkdir -p "$WORK/site/app"
for file in pcm-player.min.js unmute.min.js; do
    docker cp -q "$CONTAINER:/opt/noVNC/app/$file" "$WORK/site/app/"
done
# The overlay below replaces the image's cursor.js, and the firefox service also mounts
# config/novnc/ui.js over the image's app/ui.js and config/firefox-services/kill over its
# /etc/services.d/app/kill (the throwaway containers above get those mounts too), which would
# hide any change a new image made to them: first check that the image's files (the ones
# tests/image_overlays.py lists) are still the ones each NAME.patch was made from, and that
# each overlay is its file plus its patch (config/cursors/README.md).
OVERLAID=$(python3 -I "$REPO/tests/image_overlays.py" --paths)
while IFS= read -r path; do
    mkdir -p "$WORK/image-root$(dirname "$path")"
    docker cp -q "$CONTAINER:$path" "$WORK/image-root$path"
done <<<"$OVERLAID"
python3 -I "$REPO/tests/image_overlays.py" "$WORK/image-root"
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

# merged_result RECONNECT MUTED: web-ui-audio.mjs's two parts' results (JSON, or
# why a part did not run) as one result, their cases in the order of the two
# parts; {"error"} naming each part that did not finish.
merged_result() {
    python3 -I -c '
import json, sys
errors, parts = [], []
for name, text in (("reconnect", sys.argv[1]), ("muted", sys.argv[2])):
    try:
        result = json.loads(text)
    except ValueError:
        result = None
    if not isinstance(result, dict):
        errors.append(name + " part: " + (text.strip() or "no result"))
        continue
    parts.append(result)
    complete = (
        type(result.get("total")) is int
        and type(result.get("failed")) is int
        and isinstance(result.get("failures"), list)
        and isinstance(result.get("cases"), list)
    )
    if not complete:
        errors.append(name + " part: " + str(result.get("error", "no total")))
cases = [case for part in parts if isinstance(part.get("cases"), list) for case in part["cases"]]
if errors:
    merged = {"error": "; ".join(errors), "cases": cases}
else:
    merged = {
        "total": sum(part["total"] for part in parts),
        "failed": sum(part["failed"] for part in parts),
        "failures": [name for part in parts for name in part["failures"]],
        "cases": cases,
    }
# As JSON.stringify writes it (the parts are written so).
print(json.dumps(merged, separators=(",", ":"), ensure_ascii=False))
' "$1" "$2"
}

PORT=${PORTS[0]}
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
URL="http://127.0.0.1:$PORT/harness.html"
AUDIO_URL="http://127.0.0.1:$PORT/audio-harness.html"
for _ in $(seq 1 50); do
    curl -sf -o /dev/null "$URL" && break
    sleep 0.1
done

# The local harnesses, while the containers come up.
for i in ${kinds[@]+"${!kinds[@]}"}; do
    kind=${kinds[$i]}
    mkdir -p "$WORK/profiles/$kind" "$WORK/profiles/$kind-audio"
    start_job "$kind-harnesses" local_harnesses "$kind" "${binaries[$i]}" \
        "${PORTS[$((4 + 5 * i))]}" "${PORTS[$((5 + 5 * i))]}"
done

versions=()
for i in ${kinds[@]+"${!kinds[@]}"}; do
    if [[ "${kinds[$i]}" == chrome ]]; then
        versions+=("$("${binaries[$i]}" --version | sed 's/ *$//')")
    else
        versions+=("$("${binaries[$i]}" --version)")
    fi
done

# web-ui-audio.mjs's cases (its two parts together) and web-ui-windows.mjs's.
WEB_UI_CASES=19
WINDOWS_CASES=3

# report LABEL RESULT COUNT: prints ok or FAIL for a harness RESULT of COUNT cases.
report() {
    if result_ok "$2" "$3"; then
        echo "ok    $1: $2"
    else
        echo "FAIL  $1 (expected $3 cases, none failed): ${2:-no result in page}"
        failures=$((failures + 1))
    fi
}

# result KIND-NAME: a job's result, or nothing if it left none.
result() { cat "$WORK/results/$1" 2>/dev/null || true; }

# Each job, in the order started; a job that did not end well is a failure.
for i in ${JOB_PIDS[@]+"${!JOB_PIDS[@]}"}; do
    status=0
    wait "${JOB_PIDS[$i]}" || status=$?
    # Anything of it still running (it should have stopped all it started).
    stop_job "${JOB_PIDS[$i]}"
    if ((status != 0)); then
        echo "FAIL  job ${JOB_NAMES[$i]} exited with status $status"
        failures=$((failures + 1))
    fi
done
JOB_PIDS=()

for i in ${kinds[@]+"${!kinds[@]}"}; do
    kind=${kinds[$i]}
    version=${versions[$i]}
    report "$version cursor" "$(result "$kind-cursor")" "$EXPECTED"
    report "$version audio" "$(result "$kind-audio")" "$AUDIO_CASES"
    report "$version web UI" \
        "$(merged_result "$(result "$kind-reconnect")" "$(result "$kind-muted")")" \
        "$WEB_UI_CASES"
    report "$version windows" "$(result "$kind-windows")" "$WINDOWS_CASES"
    # What the jobs printed besides their results (errors from the tools they ran).
    for job in harnesses reconnect muted windows; do
        if [[ -s "$WORK/logs/$kind-$job" ]]; then
            echo "      $kind-$job output:"
            sed 's/^/      /' "$WORK/logs/$kind-$job"
        fi
    done
done

if ((${#kinds[@]} == 0)); then
    echo "FAIL  no browser found (looked for $CHROME and $FIREFOX)"
    exit 1
fi
if ((failures > 0)); then
    exit 1
fi
echo "browser checks passed in ${#kinds[@]} browser(s)"
