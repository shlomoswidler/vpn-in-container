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
# Scenario 3 opens a normal (non-kiosk) window and drags empty tab-strip and
# toolbar space, and Alt+drags inside the page, while the button is held. None
# of these may start an Openbox move or resize, which would show Openbox's
# 1-bit cursors (and Alt+Right drag would unmaximize Firefox).
#
# Scenario 4 opens the Library window, which Openbox decorates, and checks that
# its title bar, edges and title-bar drag show Openbox core glyphs the patched
# noVNC recognizes (config/novnc/core-glyphs.js).
#
# Scenario 5 checks that Firefox stays one maximized window: tab drags out of the
# strip, new-window shortcuts and window-closing shortcuts (config/firefox-autoconfig/,
# config/firefox-profile/customKeys.json and the single-window FF_PREF_* entries).
#
# Scenario 6 checks that Firefox's "Private browsing" indicator shows in the tab
# strip (userChrome.css shows it when permanent private browsing is on).
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

# Starts a normal Firefox window (not kiosk) on about:blank, so the tab strip
# and toolbar exist. Sets WINDOW to Firefox's X window id.
start_firefox_windowed() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$CONTAINER" --network none --shm-size 1g \
        "${SERVICE_ARGS[@]}" \
        -e FF_OPEN_URL=about:blank \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        "$IMAGE" >/dev/null
    echo "waiting for the Firefox window..."
    for _ in $(seq 1 90); do
        if in_x xdotool search --classname Navigator >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    WINDOW=$(in_x xdotool search --classname Navigator | head -n 1) || {
        echo "FAIL: Firefox never opened a window" >&2
        docker logs "$CONTAINER" 2>&1 | tail -30 >&2
        exit 1
    }
    sleep 6  # let the toolbars finish layout
}

# The display size the firefox service asks for, as "WIDTHxHEIGHT".
display_size() {
    local arg width="" height=""
    for arg in "${SERVICE_ARGS[@]}"; do
        case "$arg" in
            DISPLAY_WIDTH=*) width=${arg#*=} ;;
            DISPLAY_HEIGHT=*) height=${arg#*=} ;;
        esac
    done
    echo "${width}x${height}"
}

# Presses BUTTON (with MODIFIER, or "none") at (X,Y), drags to (X2,Y2), reads
# the VNC cursor there while the button is still held, releases, and checks
# the cursor's classification and that the window still covers the screen.
check_drag() {
    local label=$1 modifier=$2 button=$3 x=$4 y=$5 x2=$6 y2=$7 expected=$8
    local step summary actual geometry
    checks=$((checks + 1))
    in_x xdotool mousemove "$x" "$y"
    sleep 0.5
    if [[ "$modifier" != none ]]; then
        in_x xdotool keydown "$modifier"
    fi
    in_x xdotool mousedown "$button"
    for step in 1 2 3 4 5; do
        in_x xdotool mousemove $((x + (x2 - x) * step / 5)) $((y + (y2 - y) * step / 5))
        sleep 0.05
    done
    summary=$(docker run --rm --network "container:$CONTAINER" \
        -v "$E2E_DIR:/e2e:ro" -v "$WORK:/out" "$PROBE_IMAGE" \
        python -I /e2e/rfb_cursor_probe.py 127.0.0.1 5900 "$x2" "$y2" "/out/$label")
    in_x xdotool mouseup "$button"
    if [[ "$modifier" != none ]]; then
        in_x xdotool keyup "$modifier"
    fi
    in_x xdotool key Escape  # closes the context menu a right-button drag opens
    sleep 0.5
    actual=$(node "$E2E_DIR/decode.mjs" "$summary" "$WORK/$label.rgba")
    geometry=$(in_x xdotool getwindowgeometry "$WINDOW" | tr -s ' ' | tr '\n' ' ')
    if [[ "$actual" == "$expected" &&
        "$geometry" == *"Position: 0,0 "*"Geometry: $(display_size) "* ]]; then
        printf 'ok    %-16s %-8s %s\n' "$label" "$actual" "$geometry"
    else
        printf 'FAIL  %-16s expected %-8s got %-12s %s %s\n' \
            "$label" "$expected" "$actual" "$geometry" "$summary"
        failures=$((failures + 1))
    fi
}

echo "== scenario 3: toolbar and Alt drags do not start an Openbox move/resize"
start_firefox_windowed
# Coordinates assume the 1920x1080 display and a fresh profile with one tab.
check_drag tab-strip-gutter none 1 1000 20 1150 22 default
check_drag toolbar-space none 1 1750 64 1780 66 default
check_drag alt-left-drag alt 1 900 500 1100 600 default
check_drag alt-right-drag alt 3 1500 800 1200 600 default

# Hovers (X,Y) and checks the cursor's classification equals EXPECTED.
check_point() {
    local label=$1 x=$2 y=$3 expected=$4 summary actual
    checks=$((checks + 1))
    summary=$(docker run --rm --network "container:$CONTAINER" \
        -v "$E2E_DIR:/e2e:ro" -v "$WORK:/out" "$PROBE_IMAGE" \
        python -I /e2e/rfb_cursor_probe.py 127.0.0.1 5900 "$x" "$y" "/out/$label")
    actual=$(node "$E2E_DIR/decode.mjs" "$summary" "$WORK/$label.rgba")
    if [[ "$actual" == "$expected" ]]; then
        printf 'ok    %-20s %-16s (%d,%d)\n' "$label" "$actual" "$x" "$y"
    else
        printf 'FAIL  %-20s expected %-16s got %-16s (%d,%d) %s\n' \
            "$label" "$expected" "$actual" "$x" "$y" "$summary"
        failures=$((failures + 1))
    fi
}

# Openbox decorates secondary windows such as the Library, and its title bar,
# edges and title-bar drag use Openbox's 1-bit core glyphs. The patched noVNC
# must recognize each (decode.mjs reports "glyph:<keyword>"). Continues in the
# scenario 3 container.
echo "== scenario 4: Openbox's own cursors on a decorated window are recognized"
in_x xdotool windowactivate --sync "$WINDOW" key ctrl+shift+o
LIBRARY=""
for _ in $(seq 1 20); do
    LIBRARY=$(in_x xdotool search --name '^Library$' 2>/dev/null | head -n 1) || true
    [[ -n "$LIBRARY" ]] && break
    sleep 0.5
done
if [[ -z "$LIBRARY" ]]; then
    echo "FAIL: the Library window did not open" >&2
    exit 1
fi
sleep 2
# Client area position and size; Openbox's frame surrounds it.
read -r lib_x lib_y lib_w lib_h < <(in_x xdotool getwindowgeometry "$LIBRARY" \
    | sed -n -e 's/.*Position: \([0-9]*\),\([0-9]*\).*/\1 \2/p' \
        -e 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | paste -sd ' ' -)
center_x=$((lib_x + lib_w / 2))
# Measured on v26.09.1 (Library client area at 1,20): the title bar covers
# 2-15 px above the client area, the top resize edge is the frame's top row,
# and the bottom resize edge covers 0-2 px below the client area.
check_point library-title-bar "$center_x" $((lib_y - 10)) glyph:default
check_point library-top-edge "$center_x" $((lib_y - 18)) glyph:n-resize
check_point library-bottom-edge "$center_x" $((lib_y + lib_h + 1)) glyph:s-resize
check_drag library-title-drag none 1 "$center_x" $((lib_y - 10)) \
    $((center_x + 100)) $((lib_y + 90)) glyph:move

# Drags with the left button from (X,Y) to (X2,Y2) in 20 steps, as a person would.
drag() {
    local x=$1 y=$2 x2=$3 y2=$4 step
    in_x xdotool mousemove "$x" "$y"
    sleep 0.5
    in_x xdotool mousedown 1
    sleep 0.3
    for step in $(seq 1 20); do
        in_x xdotool mousemove $((x + (x2 - x) * step / 20)) $((y + (y2 - y) * step / 20))
        sleep 0.05
    done
    sleep 0.8
    in_x xdotool mouseup 1
}

# Runs the remaining arguments as a command, then checks that Firefox still has
# exactly one browser window, the original one, maximized at 0,0 over the whole
# display, and that the container is still running (closing Firefox's last
# window stops the container).
check_single_window() {
    local label=$1 windows geometry
    shift
    checks=$((checks + 1))
    "$@" || true
    sleep 3
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]]; then
        printf 'FAIL  %-22s the container stopped (Firefox exited)\n' "$label"
        failures=$((failures + 1))
        return
    fi
    windows=$(in_x xdotool search --onlyvisible --classname Navigator 2>/dev/null |
        paste -sd ' ' -) || true
    geometry=$(in_x xdotool getwindowgeometry "$WINDOW" 2>/dev/null |
        tr -s ' ' | paste -sd ' ' -) || true
    if [[ "$windows" == "$WINDOW" &&
        "$geometry" == *"Position: 0,0 "*"Geometry: $(display_size)"* ]]; then
        printf 'ok    %-22s %s\n' "$label" "$geometry"
    else
        printf 'FAIL  %-22s windows: %s main: %s\n' "$label" "$windows" "$geometry"
        failures=$((failures + 1))
    fi
}

# Firefox is a single window here: dropping a tab outside the tab strip must not
# un-maximize the window or open a new one, new-window shortcuts must not open
# one, and the window-closing shortcuts must not close the only one.
echo "== scenario 5: Firefox stays one maximized window"
start_firefox_windowed
in_x xdotool windowactivate --sync "$WINDOW"
# Coordinates assume the 1920x1080 display; the first tab's handle is at (100,20).
check_single_window only-tab-dragged-down drag 100 20 1500 600
check_single_window only-tab-dragged-left drag 100 20 300 700
check_single_window ctrl-n in_x xdotool key ctrl+n
check_single_window ctrl-shift-p in_x xdotool key ctrl+shift+p
in_x xdotool windowactivate --sync "$WINDOW" key ctrl+t
sleep 1.5
check_single_window second-tab-torn-off drag 100 20 1500 600
# These come last: a failure here closes Firefox and stops the container.
check_single_window ctrl-shift-w in_x xdotool key ctrl+shift+w
check_single_window ctrl-w-every-tab in_x xdotool key ctrl+w sleep 1 key ctrl+w sleep 1 key ctrl+w

# Counts the pixels within TOLERANCE of COLOR (RRGGBB) in the screen region
# X Y W H, read over VNC; prints rfb_color_probe.py's JSON summary.
count_color() {
    docker run --rm --network "container:$CONTAINER" \
        -v "$E2E_DIR:/e2e:ro" "$PROBE_IMAGE" \
        python -I /e2e/rfb_color_probe.py 127.0.0.1 5900 "$@"
}

# With permanent private browsing on, Firefox's own "Private browsing" indicator
# (userChrome.css) shows at the end of the tab strip. Its mask icon has a fixed
# #8000D7 fill; measured on v26.09.1: about 90 such pixels in the 44px strip.
echo "== scenario 6: the private browsing indicator is shown"
start_firefox_windowed
checks=$((checks + 1))
size=$(display_size)
summary=$(count_color 0 0 "${size%x*}" 44 8000d7 16)
matches=$(sed -n 's/.*"matches": \([0-9]*\).*/\1/p' <<<"$summary")
if ((${matches:-0} >= 50)); then
    printf 'ok    %-22s %s\n' private-indicator "$summary"
else
    printf 'FAIL  %-22s mask icon not in the tab strip: %s\n' private-indicator "$summary"
    failures=$((failures + 1))
fi

if ((failures > 0)); then
    echo "$failures of $checks check(s) failed"
    exit 1
fi
echo "all $checks checks passed"
