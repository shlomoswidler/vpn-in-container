#!/usr/bin/env bash
# End-to-end test of the native cursor integration, server side.
#
# Starts a throwaway container from the firefox service's image with the
# service's browser settings (XCURSOR_*, display and FF_PREF_* env vars, plus every
# read-only mount under /usr/share/icons, /opt/noVNC and /etc/cont-init.d),
# taken from `docker compose config` so the test follows docker-compose.yml.
# The container has no network. Firefox opens cursor-page.html in kiosk mode;
# for each cell the VNC probe moves the pointer there and reads the cursor the
# VNC server sends, and decode.mjs classifies it with the noVNC decoder. It also
# checks that every FF_PREF_* entry in docker-compose.yml reached prefs.js.
#
# Scenario 2 removes two names from a copy of the theme to check that missing
# names fall back as documented in config/cursors/README.md.
#
# Usage: tests/e2e/run.sh   (needs docker, python3 and node on the host)

set -euo pipefail

E2E_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$E2E_DIR/../.." && pwd)
CONTAINER="native-cursor-e2e-$$"
PROBE_IMAGE=python:3.13-alpine
WORK=$(mktemp -d)

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Expected classification per page cell, in page order.
EXPECTED=(
    default context-menu help pointer progress wait
    cell crosshair text vertical-text alias copy
    move no-drop not-allowed grab grabbing all-scroll
    col-resize row-resize n-resize e-resize s-resize w-resize
    ne-resize nw-resize se-resize sw-resize ew-resize ns-resize
    nesw-resize nwse-resize zoom-in zoom-out
    "default"      # cursor: auto (no text at the cell center)
    "grab"         # cursor: -moz-grab
    "transparent"  # cursor: none
    "image:16x16"  # cursor: url(16x16 red square)
)
CELL_W=320
CELL_H=135
COLUMNS=6

docker compose -f "$REPO/docker-compose.yml" config --format json \
    | python3 -I "$E2E_DIR/service_args.py" > "$WORK/service-args"

IMAGE=$(head -n 1 "$WORK/service-args")
SERVICE_ARGS=()
while IFS= read -r arg; do
    SERVICE_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args")
echo "image: $IMAGE"
printf '  %s\n' "${SERVICE_ARGS[@]}" | paste -d ' ' - -
NATIVE_CSS_SOURCE="$REPO/config/cursors/native-css"
if [[ " ${SERVICE_ARGS[*]} " != *" $NATIVE_CSS_SOURCE:"* ]]; then
    echo "FAIL: the firefox service does not mount $NATIVE_CSS_SOURCE" >&2
    exit 1
fi

# Starts the test container with the native-css theme from THEME_DIR and waits
# for the test page. Sets WINDOW to Firefox's X window id.
start_firefox() {
    local theme_dir=$1 args=() arg
    for arg in "${SERVICE_ARGS[@]}"; do
        args+=("${arg/#$NATIVE_CSS_SOURCE:/$theme_dir:}")
    done
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$CONTAINER" --network none --shm-size 1g \
        "${args[@]}" \
        -e FF_KIOSK=1 \
        -e FF_OPEN_URL=file:///e2e/cursor-page.html \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        -v "$E2E_DIR/cursor-page.html:/e2e/cursor-page.html:ro" \
        "$IMAGE" >/dev/null

    echo "waiting for Firefox to show the test page..."
    for _ in $(seq 1 90); do
        if in_x xdotool search --name 'native cursor e2e' >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    WINDOW=$(in_x xdotool search --name 'native cursor e2e' | head -n 1) || {
        echo "FAIL: Firefox never showed the test page" >&2
        docker logs "$CONTAINER" 2>&1 | tail -30 >&2
        exit 1
    }
    sleep 2  # let the page finish layout
}

# The image runs X and Firefox as USER_ID, which defaults to 1000.
in_x() { docker exec -u 1000 -e DISPLAY=:0 "$CONTAINER" "$@"; }

failures=0
checks=0

# Hovers page cell INDEX and checks the cursor's classification equals
# EXPECTED. "image:any" accepts an ordinary image of any size.
check_cell() {
    local index=$1 expected=$2 column row x y summary actual
    checks=$((checks + 1))
    column=$((index % COLUMNS))
    row=$((index / COLUMNS))
    x=$((column * CELL_W + CELL_W / 2))
    y=$((row * CELL_H + CELL_H / 2))
    summary=$(docker run --rm --network "container:$CONTAINER" \
        -v "$E2E_DIR:/e2e:ro" -v "$WORK:/out" "$PROBE_IMAGE" \
        python -I /e2e/rfb_cursor_probe.py 127.0.0.1 5900 "$x" "$y" "/out/cell$index")
    actual=$(node "$E2E_DIR/decode.mjs" "$summary" "$WORK/cell$index.rgba")
    if [[ "$actual" == "$expected" ]] ||
        [[ "$expected" == "image:any" && "$actual" == image:* ]]; then
        printf 'ok    %-14s (%4d,%4d)\n' "$actual" "$x" "$y"
    else
        printf 'FAIL  expected %-14s got %-14s (%4d,%4d) %s\n' \
            "$expected" "$actual" "$x" "$y" "$summary"
        failures=$((failures + 1))
    fi
}

# Checks that every FF_PREF_* entry from docker-compose.yml reached Firefox as
# a real preference. The image splits each value on its first "=" into a pref
# name and value; a value without "=" silently becomes a pref named after the
# whole string (so "autostart:true" never turned private browsing on).
check_prefs() {
    local i env name value pref_value line
    for ((i = 0; i < ${#SERVICE_ARGS[@]}; i++)); do
        env=${SERVICE_ARGS[$i]}
        [[ "${SERVICE_ARGS[$((i - 1))]:-}" == "-e" && "$env" == FF_PREF_* ]] || continue
        checks=$((checks + 1))
        name=${env%%=*}
        value=${env#*=}
        if [[ "$value" != *=* ]]; then
            echo "FAIL  $name=$value is not <pref name>=<value>"
            failures=$((failures + 1))
            continue
        fi
        pref_value=${value#*=}
        line="user_pref(\"${value%%=*}\", $pref_value);"
        if docker exec "$CONTAINER" grep -qxF "$line" /config/profile/prefs.js; then
            echo "ok    $name -> $line"
        else
            echo "FAIL  $name: prefs.js has no line $line"
            failures=$((failures + 1))
        fi
    done
}

echo "== scenario 1: the theme as committed"
start_firefox "$NATIVE_CSS_SOURCE"
check_prefs
checks=$((checks + 1))
geometry=$(in_x xdotool getwindowgeometry "$WINDOW" | tr -s ' ' | tr '\n' ' ')
if [[ "$geometry" == *"Position: 0,0 "* ]]; then
    echo "ok    Firefox window starts at 0,0 (no Openbox top border)"
else
    echo "FAIL  Firefox window geometry: $geometry"
    failures=$((failures + 1))
fi
for i in "${!EXPECTED[@]}"; do
    check_cell "$i" "${EXPECTED[$i]}"
done

# Names the theme lacks: GDK tries a legacy name, then left_ptr. "help" has no
# usable legacy name, so it should end at left_ptr, the "default" marker.
# "crosshair" is also a core cursor font glyph, so it should become that 1-bit
# image. "text" stays in the theme as a control.
echo "== scenario 2: theme without help and crosshair (fallback behavior)"
cp -R "$NATIVE_CSS_SOURCE" "$WORK/reduced-theme"
rm "$WORK/reduced-theme/cursors/help" "$WORK/reduced-theme/cursors/crosshair"
start_firefox "$WORK/reduced-theme"
check_cell 2 "default"   # cursor: help
check_cell 7 "image:any" # cursor: crosshair
check_cell 8 "text"      # cursor: text

if ((failures > 0)); then
    echo "$failures of $checks check(s) failed"
    exit 1
fi
echo "all $checks checks passed"
