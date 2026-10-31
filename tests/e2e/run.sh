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
# strip, new-window shortcuts, a Shift+clicked link, a window.open() pop-up and
# window-closing shortcuts (config/firefox-autoconfig/,
# config/firefox-profile/customKeys.json and the single-window FF_PREF_* entries).
# After each, it checks the window's tabs (single-window-page.html titles each
# page uniquely).
#
# Scenario 6 checks that Firefox's "Private browsing" indicator shows in the tab
# strip (userChrome.css shows it when permanent private browsing is on).
#
# Scenario 7 checks the Firefox half of the .torrent handoff to qBittorrent: a
# .torrent link downloads, without a prompt, into the directory the firefox
# service mounts at /config/downloads (here a temporary directory). A server
# inside the container's network namespace serves the file.
#
# Scenario 8 checks that WebRTC offers a page no host candidate (no local
# address), even a page that captures the microphone, while a STUN server's
# reflexive address still comes through. Dummy interfaces and a STUN server in
# the container's network namespace stand in for the network.
#
# Scenario 9 checks that a page's sound reaches the web UI's audio stream
# (WEB_AUDIO=1): audio-page.html plays a 1000 Hz tone on the left channel and
# 1500 Hz on the right after a click. It checks each hop: PulseAudio, the
# recorder and nginx's /websockify-audio are set up, the web UI is told audio
# is supported, Firefox holds a PulseAudio connection, the recorder's socket
# carries the tone, and the WebSocket the web UI reads carries it at the right
# rate in whole samples (ws_audio_probe.py), with silence before the click and
# after the tone stops.
#
# Usage: tests/e2e/run.sh   (needs docker, python3 and node on the host)

set -euo pipefail

E2E_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$E2E_DIR/../.." && pwd)
CONTAINER="native-cursor-e2e-$$"
# Runs the VNC probes. Pinned by tag and multi-arch index digest, like the
# images in docker-compose.yml, so results can't change without a repo change.
PROBE_IMAGE=python:3.13.18-alpine3.24@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
WORK=$(mktemp -d)

cleanup() {
    docker rm -f "$CONTAINER-web" "$CONTAINER-stun" "$CONTAINER-novnc" "$CONTAINER" \
        >/dev/null 2>&1 || true
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

docker compose -f "$REPO/docker-compose.yml" config --format json > "$WORK/compose.json"
python3 -I "$E2E_DIR/service_args.py" < "$WORK/compose.json" > "$WORK/service-args"

IMAGE=$(head -n 1 "$WORK/service-args")
SERVICE_ARGS=()
while IFS= read -r arg; do
    SERVICE_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args")
echo "image: $IMAGE"
# One option per line, with its value if it has one (--read-only has none).
for ((i = 0; i < ${#SERVICE_ARGS[@]}; i++)); do
    if [[ "${SERVICE_ARGS[$i]}" == --read-only ]]; then
        printf '  %s\n' "${SERVICE_ARGS[$i]}"
    else
        printf '  %s   %s\n' "${SERVICE_ARGS[$i]}" "${SERVICE_ARGS[$((i + 1))]}"
        i=$((i + 1))
    fi
done
NATIVE_CSS_SOURCE="$REPO/config/cursors/native-css"
if [[ " ${SERVICE_ARGS[*]} " != *" $NATIVE_CSS_SOURCE:"* ]]; then
    echo "FAIL: the firefox service does not mount $NATIVE_CSS_SOURCE" >&2
    exit 1
fi

# The firefox service mounts config/novnc/cursor.js and ui.js over the image's, which would hide
# any change a new image made to them. The image's own files (from a container that is created,
# never started, so no mount covers them) must still be the ones config/novnc/cursor.js.patch
# and ui.js.patch were made from (config/cursors/README.md).
docker create --name "$CONTAINER-novnc" "$IMAGE" >/dev/null
mkdir -p "$WORK/image-novnc/core/util" "$WORK/image-novnc/app"
docker cp -q "$CONTAINER-novnc:/opt/noVNC/core/util/cursor.js" "$WORK/image-novnc/core/util/"
docker cp -q "$CONTAINER-novnc:/opt/noVNC/app/ui.js" "$WORK/image-novnc/app/"
docker rm "$CONTAINER-novnc" >/dev/null
python3 -I "$REPO/tests/novnc_patch.py" "$WORK/image-novnc"

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
# Scenario coordinates are fractions of this size, or offsets from its edges
# for the toolbar items Firefox anchors there.
IFS=x read -r DISPLAY_W DISPLAY_H <<<"$(display_size)"
if ! [[ "$DISPLAY_W" =~ ^[0-9]+$ && "$DISPLAY_H" =~ ^[0-9]+$ ]]; then
    echo "FAIL: the firefox service sets no numeric DISPLAY_WIDTH/DISPLAY_HEIGHT" >&2
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
# The image writes each as a user_pref line in prefs.js at every start, but
# when Firefox rewrites prefs.js it leaves out a user value equal to the
# default. Such an entry passes if one of Firefox's default pref files sets the
# same value (it is then in effect either way, and the line comes back at the
# next start if the default changes).
FIREFOX_DEFAULT_PREFS="/usr/lib/firefox/defaults/pref /usr/lib/firefox/browser/defaults/preferences"
check_prefs() {
    local i env name value pref_value line default
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
        default="pref(\"${value%%=*}\", $pref_value);"
        if docker exec "$CONTAINER" grep -qxF "$line" /config/profile/prefs.js; then
            echo "ok    $name -> $line"
        elif docker exec "$CONTAINER" sh -c "grep -qxF -r -e '$default' $FIREFOX_DEFAULT_PREFS"; then
            echo "ok    $name -> the default is the same: $default"
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

# Starts a normal Firefox window (not kiosk), so the tab strip and toolbar
# exist, on the test page PAGE (blank-page.html by default) and waits until
# its window title contains TITLE. Further arguments go to `docker run`. Sets
# WINDOW to Firefox's X window id.
start_firefox_windowed() {
    local page=${1:-blank-page.html} title=${2:-e2e blank page}
    shift $(($# < 2 ? $# : 2))
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$CONTAINER" --network none --shm-size 1g \
        "${SERVICE_ARGS[@]}" "$@" \
        -e "FF_OPEN_URL=file:///e2e/$page" \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        -v "$E2E_DIR:/e2e:ro" \
        "$IMAGE" >/dev/null
    echo "waiting for Firefox to show $page..."
    WINDOW=""
    for _ in $(seq 1 90); do
        WINDOW=$(in_x xdotool search --classname Navigator 2>/dev/null | head -n 1) || true
        if [[ -n "$WINDOW" ]] &&
            [[ "$(in_x xdotool getwindowname "$WINDOW" 2>/dev/null)" == *"$title"* ]]; then
            return 0
        fi
        sleep 1
    done
    echo "FAIL: Firefox never showed $page" >&2
    docker logs "$CONTAINER" 2>&1 | tail -30 >&2
    exit 1
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
# A fresh profile with one tab. The tab strip (y 20) and toolbar (y 64) rows are
# Firefox's own fixed sizes. Empty tab-strip space is right of the middle (the
# one tab and the new-tab button are at the left); empty toolbar space is left
# of the buttons Firefox anchors to the right edge. The Alt drags are in the
# page, around its center. Measured at 1920x1080, where these are the points
# (1000,20), (1750,64), (900,500) and (1500,800).
mid_x=$((DISPLAY_W / 2))
mid_y=$((DISPLAY_H / 2))
check_drag tab-strip-gutter none 1 $((mid_x + 40)) 20 $((mid_x + 190)) 22 default
check_drag toolbar-space none 1 $((DISPLAY_W - 170)) 64 $((DISPLAY_W - 140)) 66 default
check_drag alt-left-drag alt 1 $((mid_x - 60)) $((mid_y - 40)) \
    $((mid_x + 140)) $((mid_y + 60)) default
check_drag alt-right-drag alt 3 $((mid_x + 540)) $((mid_y + 260)) \
    $((mid_x + 240)) $((mid_y + 60)) default

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
check_point library-top-edge "$center_x" $((lib_y - 18)) glyph:ns-resize
check_point library-bottom-edge "$center_x" $((lib_y + lib_h + 1)) glyph:ns-resize
check_drag library-title-drag none 1 "$center_x" $((lib_y - 10)) \
    $((center_x + 100)) $((lib_y + 90)) glyph:move

# Prints the title of the page Firefox shows: its window title without the
# " — Mozilla Firefox" suffix, or "" for a page without a title.
shown_title() {
    local name
    name=$(in_x xdotool getwindowname "$WINDOW") || return 1
    name=${name% — Mozilla Firefox}
    [[ "$name" == "Mozilla Firefox" ]] && name=""
    printf '%s\n' "$name"
}

# Waits up to 15 s until the title of the page Firefox shows starts with
# PREFIX (is "" when PREFIX is ""), and prints that title.
wait_title() {
    local prefix=$1 deadline=$((SECONDS + 15)) title
    while ((SECONDS < deadline)); do
        if title=$(shown_title) &&
            { [[ -z "$prefix" && -z "$title" ]] || [[ -n "$prefix" && "$title" == "$prefix"* ]]; }; then
            printf '%s\n' "$title"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Drags with the left button from (X,Y) to (X2,Y2) in 20 steps, as a person
# would (the pauses pace the gesture). Returns non-zero if any step fails.
drag() {
    local x=$1 y=$2 x2=$3 y2=$4 step
    in_x xdotool mousemove "$x" "$y" sleep 0.5 mousedown 1 sleep 0.3 || return 1
    for step in $(seq 1 20); do
        in_x xdotool mousemove $((x + (x2 - x) * step / 20)) $((y + (y2 - y) * step / 20)) \
            sleep 0.05 || return 1
    done
    in_x xdotool sleep 0.8 mouseup 1
}

# The title prefix of single-window-page.html's page NAME ("untitled" is a
# page without a title, such as a new tab).
tab_prefix() {
    if [[ "$1" == untitled ]]; then
        echo ""
    else
        echo "sw:$1 "
    fi
}

# Prints the ids of Firefox's visible browser windows, space-separated.
browser_windows() {
    in_x xdotool search --onlyvisible --classname Navigator 2>/dev/null | paste -sd ' ' -
}

# Checks that Firefox's window has exactly the tabs NAMES (distinct page names,
# see tab_prefix), in order, and ends with the last one shown. Alt+K shows tab
# K, Alt+9 the last tab, and Ctrl+PageDown from the last tab wraps to the
# first. Every step waits for the title to change to the expected page, so a
# key Firefox has not handled yet can't pass for one it has. With one tab
# nothing can change, so Ctrl+PageDown gets SETTLE_S to show a second tab.
# Prints what differs and returns 1 on a mismatch.
check_tabs() {
    local names=() titles=() n k title
    read -r -a names <<<"$1"
    n=${#names[@]}
    if ((n == 1)); then
        if ! title=$(wait_title "$(tab_prefix "${names[0]}")"); then
            echo "the window shows '$(shown_title)', not ${names[0]}"
            return 1
        fi
        in_x xdotool key ctrl+Next sleep "$SETTLE_S" || return 1
        if [[ "$(shown_title)" != "$title" ]]; then
            echo "a second tab exists: '$(shown_title)'"
            return 1
        fi
        return 0
    fi
    # Start from the last tab, so Alt+1 must change the page shown.
    in_x xdotool key alt+9 || return 1
    if ! wait_title "$(tab_prefix "${names[n - 1]}")" >/dev/null; then
        echo "the last tab is '$(shown_title)', not ${names[n - 1]}"
        return 1
    fi
    for ((k = 1; k <= n; k++)); do
        in_x xdotool key "alt+$k" || return 1
        if ! title=$(wait_title "$(tab_prefix "${names[k - 1]}")"); then
            echo "tab $k is '$(shown_title)', not ${names[k - 1]}"
            return 1
        fi
        titles+=("$title")
    done
    # Tab N must be the last tab: the next one is the first again.
    in_x xdotool key ctrl+Next || return 1
    if ! wait_title "${titles[0]}" >/dev/null; then
        echo "after tab $n comes '$(shown_title)', not tab 1"
        return 1
    fi
    in_x xdotool key "alt+$n" || return 1
    wait_title "${titles[n - 1]}" >/dev/null
}

# check_single_window LABEL TABS SHOWS ACTION...
# Runs ACTION, then checks that Firefox still has exactly one browser window,
# the original one, maximized at 0,0 over the whole display, that the
# container is still running (closing Firefox's last window stops it), and
# that the window has exactly the tabs TABS (see check_tabs). SHOWS is the
# page ACTION must show in that window, which the check waits for, or "-" if
# ACTION should change nothing: there is nothing to wait for then, so the
# check gives a second window SETTLE_S to appear. A failed ACTION fails.
check_single_window() {
    local label=$1 tabs=$2 shows=$3 problem="" windows="" geometry="" deadline
    shift 3
    checks=$((checks + 1))
    if ! "$@"; then
        problem="the action failed: $*"
    elif [[ "$shows" == - ]]; then
        sleep "$SETTLE_S"
    elif ! wait_title "$(tab_prefix "$shows")" >/dev/null; then
        problem="the window shows '$(shown_title)', not $shows"
    else
        # A second window may still be closing after its tabs moved.
        deadline=$((SECONDS + 15))
        until [[ "$(browser_windows || true)" == "$WINDOW" ]] || ((SECONDS >= deadline)); do
            sleep 0.2
        done
    fi
    if [[ -z "$problem" ]]; then
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]]; then
            problem="the container stopped (Firefox exited)"
        else
            windows=$(browser_windows) || true
            geometry=$(in_x xdotool getwindowgeometry "$WINDOW" 2>/dev/null |
                tr -s ' ' | paste -sd ' ' -) || true
            if [[ "$windows" != "$WINDOW" ||
                "$geometry" != *"Position: 0,0 "*"Geometry: $(display_size)"* ]]; then
                problem="windows: $windows main: $geometry"
            elif ! problem=$(check_tabs "$tabs"); then
                problem="tabs: $problem"
            fi
        fi
    fi
    if [[ -z "$problem" ]]; then
        printf 'ok    %-22s tabs: %s\n' "$label" "$tabs"
    else
        printf 'FAIL  %-22s %s\n' "$label" "$problem"
        failures=$((failures + 1))
    fi
}

# Closes the shown tab with Ctrl+W and waits until each NAME in turn is shown
# (one Ctrl+W per name).
close_tabs() {
    local name
    for name in "$@"; do
        in_x xdotool key ctrl+w || return 1
        wait_title "$(tab_prefix "$name")" >/dev/null || return 1
    done
}

# Firefox is a single window here: dropping a tab outside the tab strip must not
# un-maximize the window or open a new one, new-window shortcuts must not open
# one, links and pop-ups that ask for a new window must open as tabs in it
# (config/firefox-autoconfig/single-window.cfg and the FF_PREF_* entries), and
# the window-closing shortcuts must not close the only one. Ctrl+T, Ctrl+W and
# a tab dragged along the tab strip are controls: they must change the tabs,
# which shows the keys and drags reach Firefox.
echo "== scenario 5: Firefox stays one maximized window"
SETTLE_S=2
start_firefox_windowed single-window-page.html "sw:main "
in_x xdotool windowactivate --sync "$WINDOW"
# The first tab's handle is at (100,20) and the second's at (420,20) at any
# display size (tabs start at the left and have a fixed width). Tabs are
# dropped into the right and left parts of the page. The page's top half is
# a link and its bottom half a pop-up button.
drop_right_x=$((DISPLAY_W * 3 / 4))
drop_right_y=$((DISPLAY_H * 5 / 9))
drop_left_x=$((DISPLAY_W / 8))
drop_left_y=$((DISPLAY_H * 2 / 3))
link_y=$((DISPLAY_H * 3 / 8))
popup_y=$((DISPLAY_H * 7 / 8))
check_single_window only-tab-dragged-down main - drag 100 20 "$drop_right_x" "$drop_right_y"
check_single_window only-tab-dragged-left main - drag 100 20 "$drop_left_x" "$drop_left_y"
check_single_window ctrl-n main - in_x xdotool key ctrl+n
check_single_window ctrl-shift-p main - in_x xdotool key ctrl+shift+p
check_single_window ctrl-t "main untitled" untitled in_x xdotool key ctrl+t
check_single_window ctrl-w main main in_x xdotool key ctrl+w
# Opens a new window; single-window.cfg moves its tab into the first window.
check_single_window shift-click "main shift-click" shift-click \
    in_x xdotool mousemove "$((DISPLAY_W / 2))" "$link_y" keydown shift click 1 keyup shift
check_single_window tab-moved-along-strip "shift-click main" main drag 100 20 420 20
check_single_window second-tab-torn-off "shift-click main" - \
    drag 100 20 "$drop_right_x" "$drop_right_y"
# window.open() with a size asks for a 400x300 pop-up window.
check_single_window popup "shift-click main popup" popup \
    in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_y" click 1
# These come last: a failure here closes Firefox and stops the container.
# Closing the last tab must leave the window open with a new tab: that is
# browser.tabs.closeWindowWithLastTab=false (FF_PREF_KEEP_WINDOW_WITH_LAST_TAB).
check_single_window ctrl-shift-w "shift-click main popup" - in_x xdotool key ctrl+shift+w
check_single_window ctrl-w-every-tab untitled untitled close_tabs main shift-click untitled

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
# The tab strip may still be drawing: read it until the icon shows, up to 15 s.
deadline=$((SECONDS + 15))
while :; do
    summary=$(count_color 0 0 "$DISPLAY_W" 44 8000d7 16)
    matches=$(sed -n 's/.*"matches": \([0-9]*\).*/\1/p' <<<"$summary")
    if ((${matches:-0} >= 50 || SECONDS >= deadline)); then
        break
    fi
    sleep 1
done
if ((${matches:-0} >= 50)); then
    printf 'ok    %-22s %s\n' private-indicator "$summary"
else
    printf 'FAIL  %-22s mask icon not in the tab strip: %s\n' private-indicator "$summary"
    failures=$((failures + 1))
fi

# Firefox saves a .torrent link straight into /config/downloads, which
# qBittorrent watches. The image's default prefs set browser.download.dir to
# /config/downloads. Firefox 151 asks before saving a .torrent from a file: URL
# (measured), so the file comes over HTTP, as application/x-bittorrent, from
# torrent_server.py in the container's network namespace (the container still
# has no network).
echo "== scenario 7: a .torrent link downloads into /config/downloads without a prompt"
TORRENT_PORT=8765 # download-page.html links to this port
checks=$((checks + 1))
if ! python3 -I -c '
import json, sys
volumes = json.load(sys.stdin)["services"]["firefox"].get("volumes", [])
sys.exit(not any(v["target"] == "/config/downloads" and not v.get("read_only") for v in volumes))
' < "$WORK/compose.json"; then
    echo "FAIL  the firefox service mounts no writable directory at /config/downloads"
    failures=$((failures + 1))
else
    echo "ok    the firefox service mounts a writable directory at /config/downloads"
fi
mkdir -p "$WORK/web" "$WORK/downloads"
chmod 0777 "$WORK/downloads" # Firefox runs as the image's user
python3 -I "$REPO/tests/qbittorrent/make_torrent.py" "$WORK/torrent-content" \
    "$WORK/web/test.torrent" >/dev/null
expected_sha=$(shasum -a 256 "$WORK/web/test.torrent" | cut -d ' ' -f 1)
start_firefox_windowed download-page.html "e2e download page" \
    -v "$WORK/downloads:/config/downloads"
docker run -d --rm --name "$CONTAINER-web" --network "container:$CONTAINER" \
    -v "$E2E_DIR:/e2e:ro" -v "$WORK/web:/srv:ro" "$PROBE_IMAGE" \
    python -I /e2e/torrent_server.py "$TORRENT_PORT" /srv >/dev/null
deadline=$((SECONDS + 30))
until docker exec "$CONTAINER" wget -q -O /dev/null "http://127.0.0.1:$TORRENT_PORT/test.torrent" \
    2>/dev/null; do
    if ((SECONDS >= deadline)); then
        echo "FAIL: torrent_server.py did not start" >&2
        docker logs "$CONTAINER-web" >&2
        exit 1
    fi
    sleep 0.5
done
checks=$((checks + 1))
in_x xdotool windowactivate --sync "$WINDOW" mousemove "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))" click 1
# Firefox writes NAME.part, then renames it. A save prompt would leave only the
# .part file until someone answers it.
deadline=$((SECONDS + 30))
downloaded=""
while ((SECONDS < deadline)); do
    if [[ -f "$WORK/downloads/test.torrent" ]] &&
        ! compgen -G "$WORK/downloads/*.part" >/dev/null &&
        [[ "$(shasum -a 256 "$WORK/downloads/test.torrent" | cut -d ' ' -f 1)" == "$expected_sha" ]]; then
        downloaded=yes
        break
    fi
    sleep 0.5
done
listing=$(find "$WORK/downloads" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | paste -sd ' ' -)
# Any visible window besides the browser window, except Firefox's pop-up panels
# (role "Popup", such as the first private download's "Files stay on your
# device" notice), would be a prompt such as "Opening test.torrent".
prompts=""
for window in $(in_x xdotool search --onlyvisible --name . 2>/dev/null || true); do
    [[ "$window" != "$WINDOW" ]] || continue
    properties=$(in_x obxprop --id "$window")
    if ! grep -qxF 'WM_WINDOW_ROLE(STRING) = "Popup"' <<<"$properties"; then
        prompts+="\"$(in_x xdotool getwindowname "$window")\" "
    fi
done
if [[ -n "$downloaded" && -z "$prompts" ]]; then
    printf 'ok    %-22s /config/downloads: %s\n' torrent-download "$listing"
else
    printf 'FAIL  %-22s /config/downloads: %s; other windows: %s\n' torrent-download \
        "${listing:-(empty)}" "${prompts:-none}"
    failures=$((failures + 1))
fi

# Firefox lets a page that captures the camera or microphone (a video call)
# gather candidates on every interface and see their real addresses; for other
# pages it already offers only the default route's address, hidden behind an
# mDNS name. The FF_PREF_WEBRTC_* entries (docker-compose.yml) must keep even a
# capturing page from seeing a host address: in the VPN's namespace those are
# eth0's (the Docker network) and tun0's. The server-reflexive address (the
# VPN's exit address, as STUN servers see it) is still offered.
# Here two dummy interfaces stand in for eth0 and tun0, the second with the
# default route, and stun_server.py, listening in the namespace, reports
# STUN_MAPPED as the reflexive address. The test prefs grant the page a fake
# microphone without a prompt, and make it count as capturing. Dummy
# interfaces send nothing anywhere: the container still has no network.
echo "== scenario 8: WebRTC offers no host candidates, even to a capturing page"
STUN_MAPPED=203.0.113.7 # a documentation address (RFC 5737), on no interface
OTHER_ADDRESS=10.99.0.2 # webrtc-page.html asks for the STUN server here
DEFAULT_ADDRESS=10.98.0.2
checks=$((checks + 1))
start_firefox_windowed webrtc-page.html "e2e webrtc page" \
    -e FF_PREF_E2E_GUM_NO_PROMPT=media.navigator.permission.disabled=true \
    -e FF_PREF_E2E_GUM_FAKE=media.navigator.streams.fake=true \
    -e FF_PREF_E2E_GUM_FAKE_CAPTURES=media.navigator.permission.fake=true
docker run --rm --network "container:$CONTAINER" --cap-add NET_ADMIN "$PROBE_IMAGE" sh -c "
    ip link add e2e-other type dummy && ip addr add $OTHER_ADDRESS/24 dev e2e-other &&
    ip link set e2e-other up &&
    ip link add e2e-default type dummy && ip addr add $DEFAULT_ADDRESS/24 dev e2e-default &&
    ip link set e2e-default up && ip route add default dev e2e-default"
docker run -d --rm --name "$CONTAINER-stun" --network "container:$CONTAINER" \
    -v "$E2E_DIR:/e2e:ro" "$PROBE_IMAGE" \
    python -I /e2e/stun_server.py 3478 "$STUN_MAPPED" >/dev/null
# Port 3478 is 0D96 in /proc/net/udp.
deadline=$((SECONDS + 30))
until docker exec "$CONTAINER" grep -q ':0D96 ' /proc/net/udp; do
    if ((SECONDS >= deadline)); then
        echo "FAIL: stun_server.py did not start" >&2
        docker logs "$CONTAINER-stun" >&2
        exit 1
    fi
    sleep 0.5
done
in_x xdotool windowactivate --sync "$WINDOW" mousemove "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))" click 1
result=""
deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
    result=$(shown_title) || true
    [[ "$result" == webrtc-result* || "$result" == webrtc-error* ]] && break
    sleep 0.5
done
# "webrtc-result host=<addresses> srflx=<addresses> raddr=<addresses>": no host
# candidate, the reflexive address, and no local address anywhere (not even as
# a reflexive candidate's related address).
if [[ "$result" == "webrtc-result host= srflx=$STUN_MAPPED "* &&
    "$result" != *"$DEFAULT_ADDRESS"* && "$result" != *"$OTHER_ADDRESS"* ]]; then
    printf 'ok    %-22s %s\n' webrtc-candidates "$result"
else
    printf 'FAIL  %-22s %s\n' webrtc-candidates "${result:-(no result)}"
    failures=$((failures + 1))
fi

# With WEB_AUDIO=1 the image runs PulseAudio (a null sink, socket
# /tmp/pulseaudio.sock) for Firefox, records the sink's monitor (audiorecorder,
# socket /tmp/vnc-audio.sock: s16le, 2 channels, 44.1 kHz), and nginx relays
# that on /websockify-audio, port 5800, to the web UI's PCMPlayer. Each check
# below covers one hop, so a failure says where the sound stops. The probes run
# in the container's network namespace; the sockets are files in its /tmp, so
# the checks of those use docker exec.
echo "== scenario 9: a page's sound reaches the web UI's audio stream"
TONE=tone:1000,1500 # audio-page.html's left and right frequencies
audio_failures=$failures

# check_audio LABEL COMMAND...: ok if COMMAND succeeds; prints its output.
check_audio() {
    local label=$1 output
    shift
    checks=$((checks + 1))
    if output=$("$@" 2>&1); then
        printf 'ok    %-22s %s\n' "$label" "$output"
    else
        printf 'FAIL  %-22s %s\n' "$label" "${output:-(no output)}"
        failures=$((failures + 1))
    fi
}

# Reads the web UI's audio WebSocket for SECONDS and checks it against EXPECT
# (silence or $TONE); prints ws_audio_probe.py's summary.
ws_audio() {
    docker run --rm --network "container:$CONTAINER" -v "$E2E_DIR:/e2e:ro" "$PROBE_IMAGE" \
        python -I /e2e/ws_audio_probe.py ws 127.0.0.1 5800 "$1" "$2"
}

# The audio services run and have their sockets, and nginx relays the stream.
audio_services() {
    docker exec "$CONTAINER" sh -c '
        pulseaudio=$(pgrep -x pulseaudio) && recorder=$(pgrep -x audiorecorder) &&
            echo "pulseaudio $pulseaudio, audiorecorder $recorder"'
}
audio_sockets() {
    docker exec "$CONTAINER" sh -c '
        test -S /tmp/pulseaudio.sock && test -S /tmp/vnc-audio.sock &&
            echo "/tmp/pulseaudio.sock and /tmp/vnc-audio.sock are sockets"'
}
audio_nginx() {
    docker exec "$CONTAINER" \
        grep -oF 'websockify_pass unix:/tmp/vnc-audio.sock;' /var/tmp/nginx/audio.conf
}
# The web UI shows its audio controls and opens the stream only when told to.
audio_webdata() {
    docker exec "$CONTAINER" wget -q -O - http://127.0.0.1:5800/webdata.json |
        grep -oF '"audioSupport": true'
}
# Firefox (its main process, which plays a page's sound) is told the server.
# /proc/PID/environ and /proc/PID/fd are readable only with Firefox's user and
# group.
firefox_pulse_server() {
    docker exec -u 1000:1000 "$CONTAINER" cat "/proc/$FIREFOX_PID/environ" | tr '\0' '\n' |
        grep -x 'PULSE_SERVER=unix:/tmp/pulseaudio.sock'
}

# Prints how many of Firefox's sockets are the client end of a connection to
# PulseAudio: unix_peers_probe.py lists those ends, and /proc/PID/fd links to
# each socket a process holds. Fails if nothing listens on PulseAudio's socket.
firefox_pulse_connections() {
    local clients held
    clients=$(docker run --rm --network "container:$CONTAINER" -v "$E2E_DIR:/e2e:ro" \
        "$PROBE_IMAGE" python -I /e2e/unix_peers_probe.py /tmp/pulseaudio.sock) || return 1
    held=$(docker exec -u 1000:1000 "$CONTAINER" ls -l "/proc/$FIREFOX_PID/fd" |
        sed -n 's/.*socket:\[\([0-9]*\)\].*/\1/p') || return 1
    python3 -I -c '
import json, sys
clients = json.loads(sys.argv[1])
if not clients["listening"]:
    sys.exit("nothing listens on PulseAudio'"'"'s socket: " + sys.argv[1])
held = set(sys.argv[2].split())
print(sum(1 for inode in clients["clients"] if str(inode) in held))
' "$clients" "$held"
}

# check_firefox_pulse LABEL MIN MAX: Firefox holds MIN to MAX PulseAudio connections.
check_firefox_pulse() {
    local label=$1 min=$2 max=$3 count
    checks=$((checks + 1))
    if ! count=$(firefox_pulse_connections 2>&1); then
        printf 'FAIL  %-22s %s\n' "$label" "$count"
        failures=$((failures + 1))
    elif ((min <= count && count <= max)); then
        printf 'ok    %-22s Firefox holds %s PulseAudio connection(s)\n' "$label" "$count"
    else
        printf 'FAIL  %-22s Firefox holds %s PulseAudio connection(s), expected %s to %s\n' \
            "$label" "$count" "$min" "$max"
        failures=$((failures + 1))
    fi
}

# check_title LABEL PREFIX EXPECTED: the page's title starts with PREFIX within
# 15 s, and is EXPECTED.
check_title() {
    local label=$1 prefix=$2 expected=$3 title
    checks=$((checks + 1))
    if title=$(wait_title "$prefix") && [[ "$title" == "$expected" ]]; then
        printf 'ok    %-22s %s\n' "$label" "$title"
    else
        printf 'FAIL  %-22s the page shows "%s", expected "%s"\n' \
            "$label" "$(shown_title)" "$expected"
        failures=$((failures + 1))
    fi
}

checks=$((checks + 1))
if [[ " ${SERVICE_ARGS[*]} " == *" WEB_AUDIO=1 "* ]]; then
    echo "ok    the firefox service sets WEB_AUDIO=1"
else
    echo "FAIL  the firefox service does not set WEB_AUDIO=1"
    failures=$((failures + 1))
fi
start_firefox_windowed audio-page.html "e2e audio page"
FIREFOX_PID=$(in_x xdotool getwindowpid "$WINDOW")
check_audio audio-services audio_services
check_audio audio-sockets audio_sockets
check_audio audio-nginx audio_nginx
check_audio audio-webdata audio_webdata
check_audio firefox-pulse-server firefox_pulse_server
# Negative controls for the checks after the click: nothing plays yet, and
# Firefox has no PulseAudio connection (it connects when a page plays sound).
check_audio audio-silence-before ws_audio 3 silence
check_firefox_pulse firefox-pulse-before 0 0
in_x xdotool windowactivate --sync "$WINDOW" \
    mousemove "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))" click 1
check_title audio-page-playing audio-playing "audio-playing state=running rate=44100"
check_firefox_pulse firefox-pulse-playing 1 99
# The hop before nginx: the recorder's socket. nc reads it until timeout stops
# nc (so its status is timeout's); the analysis uses the capture's last second.
docker exec "$CONTAINER" timeout 3 nc -d -U /tmp/vnc-audio.sock >"$WORK/raw-tone.pcm" || true
check_audio audio-recorder-tone \
    python3 -I "$E2E_DIR/ws_audio_probe.py" raw "$WORK/raw-tone.pcm" "$TONE"
check_audio audio-websocket-tone ws_audio 3 "$TONE"
in_x xdotool mousemove "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))" click 1
check_title audio-page-stopped audio-stopped audio-stopped
check_audio audio-silence-after ws_audio 3 silence
if ((failures > audio_failures)); then
    echo "the audio services' log:"
    docker logs "$CONTAINER" 2>&1 | grep -E '^\[(pulseaudio|audiorecorder|nginx) *\]' || true
fi

if ((failures > 0)); then
    echo "$failures of $checks check(s) failed"
    exit 1
fi
echo "all $checks checks passed"
