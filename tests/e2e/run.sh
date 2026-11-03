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
# It runs as three shards, each in a container of its own (the cells do not
# depend on each other): 1a checks the prefs, the window's position and cells
# 0-12, 1b cells 13-25, 1c cells 26-37.
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
# strip, new-window shortcuts, Ctrl+Shift+P, a Shift+clicked link, pop-ups
# (window.open() with and without a size, a target="_blank" link) and another
# private window (config/firefox-autoconfig/,
# config/firefox-profile/customKeys.json and the single-window FF_PREF_*
# entries). With permanent private browsing there is one window: no Window
# menu, Ctrl+` and Close Window (Ctrl+Shift+W, File menu) do nothing. After
# each, it checks the window's tabs (single-window-page.html titles each page
# uniquely). Then Quit & Restart: Ctrl+Q asks (Escape cancels), and Ctrl+Q, the
# File menu and the main menu restart Firefox in the same container
# (KEEP_APP_RUNNING=1), still private; so does the container's shutdown key,
# Ctrl+Alt+Shift+Q, without asking. It runs as five shards, each in a fresh
# container: 5a the only tab's drags, Ctrl+N, Ctrl+Shift+P, Ctrl+T and Ctrl+W;
# 5b the Shift+clicked link, the tab drags, the pop-ups and another private
# window; 5e, on the tabs 5b's checks leave, no Window menu, Ctrl+` and no
# Close Window, and closing every tab; 5c Ctrl+Q (cancel, then restart) and the
# File menu's Quit & Restart; 5d the main menu's Quit & Restart and the
# shutdown key.
#
# Scenarios 1-9 run with permanent private browsing on (FIREFOX_PRIVATE_BROWSING=true,
# whatever .env sets), scenario 10 (but the second start of 10g) and the end of
# scenario 6 (6s) with it off (false, the default).
#
# Scenario 6 checks that Firefox's "Private browsing" indicator shows in the tab
# strip (userChrome.css shows it when permanent private browsing is on), and
# that nothing is kept: a cookie and the history of a page are gone after the
# container restarts on the same /config, and a cookie is gone after Quit &
# Restart. `docker stop` must quit Firefox through the shutdown script's key
# within its 5 s, and the image must not start Firefox again then. Then the
# switch from on to off: on a /config that had private browsing on, with
# private browsing off, the indicator is not shown and every FF_PREF_* entry
# reached prefs.js. It runs as two shards: 6m what is kept and the clean stop,
# 6s the indicator, then the switch on a /config of its own.
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
# Scenario 10 checks private browsing off: the indicator is not shown, the
# cookie and history are kept across a restart on the same /config, private
# windows open as in Firefox itself (Ctrl+Shift+P, the File menu, "Open Link in
# New Private Window") and really are private, Firefox keeps at most one normal
# and one private window, both maximized, with each new window's or pop-up's tab
# in the window of its kind, Ctrl+` and the Window menu switch between the two
# (the shown window is X's active window and the top of Openbox's stack), Close
# Window (Ctrl+Shift+W, the Window menu) closes the private window, Quit &
# Restart reopens the normal window's tabs (not the private window's) and keeps
# the cookie, closing the last window (normal, or private after the normal one
# closed) restarts Firefox with a fresh normal window, a .torrent link still
# downloads into /config/downloads, and `docker stop` quits Firefox cleanly.
# Then the switch from off to on: on a /config that had private browsing off,
# with private browsing on, the indicator is shown and the kept cookie is not. It runs as eight shards, each
# in a fresh container: 10a the kept profile; 10b the first private windows and
# their cookies; 10c pop-ups and new windows from both windows; 10d switching
# between the windows and closing the private one; 10e Quit & Restart; 10f
# closing the last window, the download and the clean stop; 10g the switch to
# on, on a /config of its own; 10h no indicator. Each shard first makes the
# tabs, windows and cookies its checks start from, with the same actions the
# scenario used before them, and stops with a FAIL if one of those steps does
# not show its result.
#
# Scenario 11 checks that a FIREFOX_PRIVATE_BROWSING other than true or false
# stops the container at start, with the reason in its log, before the image
# writes the value into prefs.js.
#
# Scenario 12 checks the service's Firefox policies (policies.json): with them a
# clean quit archives no telemetry pings in the profile, while without them the
# same quit archives some.
#
# Usage: tests/e2e/run.sh [SCENARIO...]   (needs docker, python3 and node on the host)
#
# Without arguments, every scenario runs, in the groups SCENARIO_GROUPS lists,
# all groups at the same time: each group is a run of this script with only its
# scenarios, so it has its own containers (named after its process id) and its
# own work directory. This run reads the firefox service's configuration and
# checks the image's overlaid files once, before the groups start. When every
# group has ended, it prints each group's output in turn, then the checks of
# all groups: "all N checks passed" or "F of N check(s) failed". With SCENARIO
# ids, only those scenarios run, in order, in this process, e.g.
# `tests/e2e/run.sh 7 8` or `tests/e2e/run.sh 10c`; the number of a scenario
# that runs as shards selects all of them (`tests/e2e/run.sh 5` is 5a 5b 5c
# 5d 5e). Scenario 4 continues in scenario 3's container, so it needs 3 too.

set -euo pipefail

E2E_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$E2E_DIR/../.." && pwd)
SELF="$E2E_DIR/$(basename "$0")"
# The scenario ids: a shard of a scenario is its number and a letter.
ALL_SCENARIOS="1a 1b 1c 2 3 4 5a 5b 5c 5d 5e 6m 6s 7 8 9 10a 10b 10c 10d 10e 10f 10g 10h 11 12"
# The groups a run without arguments starts, one process each, all at the same
# time, so the run takes as long as its longest group: each group of more than
# one scenario holds short ones that run one after another. Each group must
# hold every scenario another of its scenarios continues from (4 needs 3); no
# shard continues from another. Measured on a Mac with 16 CPUs (OrbStack: 16
# CPUs, 31 GB), in seconds, the range in three runs of all the groups at once
# (45-46 s for the whole run), then in two runs of tests/run-all.sh, which
# runs every suite at once (58 s for it, e2e's groups 56 s): 1a 37-39, 44-47;
# 1b 38-39, 43-45; 1c 33-35, 43-44; 2 7 8 42, 52; 3 4 37-40, 44-48; 5a 33-37,
# 45; 5b 33-36, 45-47; 5c 35-36, 42-43; 5d 30-33, 39-43; 5e 38, 45-47; 6m
# 43-44, 53-55; 6s 29, 37-38; 9 11 12 43-45, 51-54; 10a 29-30, 40-41; 10b
# 41-42, 52-53; 10c 43-45, 55-56; 10d 39-41, 48-50; 10e 32-33, 42-44; 10f
# 45-46, 55-56; 10g 28-29, 39-40; 10h 29-31, 31.
SCENARIO_GROUPS=("1a" "1b" "1c" "2 7 8" "3 4" "5a" "5b" "5c" "5d" "5e" "6m" "6s" "9 11 12"
    "10a" "10b" "10c" "10d" "10e" "10f" "10g" "10h")
# The scenarios this run runs, as " N N ... ", in ALL_SCENARIOS order; empty
# for a run of all the groups. An argument is a scenario id, or the number of a
# scenario that runs as shards, which selects every shard of it.
SELECTED=""
for arg in "$@"; do
    known=""
    for n in $ALL_SCENARIOS; do
        if [[ "$n" == "$arg" || "$n" == "$arg"[a-z] ]]; then
            known=yes
        fi
    done
    if [[ -z "$known" ]]; then
        echo "unknown scenario: $arg (one of: $ALL_SCENARIOS; or 1, 5, 6, 10 for all their shards)" >&2
        exit 2
    fi
done
if (($# > 0)); then
    SELECTED=" "
    for n in $ALL_SCENARIOS; do
        for arg in "$@"; do
            if [[ "$n" == "$arg" || "$n" == "$arg"[a-z] ]]; then
                SELECTED+="$n "
                break
            fi
        done
    done
    if [[ "$SELECTED" == *" 4 "* && "$SELECTED" != *" 3 "* ]]; then
        echo "scenario 4 continues in scenario 3's container: select 3 too" >&2
        exit 2
    fi
fi
CONTAINER="native-cursor-e2e-$$"
# Runs the VNC probes. Pinned by tag and multi-arch index digest, like the
# images in docker-compose.yml, so results can't change without a repo change.
PROBE_IMAGE=python:3.13.18-alpine3.24@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
WORK=$(mktemp -d)
# The test containers have no network, and their resolver's server (Docker's
# default for --network none) never answers, so each lookup Firefox makes waits
# out musl's full timeout (5 s, measured). Shutting down, Firefox waits for
# those lookups, and for its experiments sync, which waits on one: a quit could
# take longer than the 5 s the image's shutdown script gives it. A loopback
# server with nothing listening refuses at once, as a network that is down
# would (docs/agents_output/debugging/shutdown-key-and-appmenu.md).
NO_DNS_ARGS=(--dns 127.0.0.1 --dns-opt timeout:1 --dns-opt attempts:1)
# The VNC probes (cursor and color) run in one long-lived container in the test
# container's network namespace, started with each test container
# (start_probe): a container per probe cost a start each (0.23 s against
# 0.04 s for a docker exec, measured).
PROBE_CONTAINER="$CONTAINER-probe"
# How often a wait for a container's start looks again (for its Firefox
# window, and in scenarios 11 and 12 for what its start leads to): each look
# is one docker exec or inspect (about 50 ms, measured), so a short interval
# costs little and ends the wait closer to when the start is done.
START_POLL_S=0.25

# The process ids of the groups a run of all of them started (run_groups).
GROUP_PIDS=()

# Stops any group still running (each removes its own containers as it exits),
# then removes this run's containers and work directory.
cleanup() {
    local pid
    for pid in ${GROUP_PIDS[@]+"${GROUP_PIDS[@]}"}; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in ${GROUP_PIDS[@]+"${GROUP_PIDS[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
    # -v: also the anonymous /config volumes of the containers not started with --rm.
    docker rm -f -v "$CONTAINER-web" "$CONTAINER-stun" "$CONTAINER-overlays" "$CONTAINER-bad" \
        "$CONTAINER-policies" "$CONTAINER-nopolicies" "$PROBE_CONTAINER" "$CONTAINER" \
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
    "default"     # cursor: auto (no text at the cell center)
    "grab"        # cursor: -moz-grab
    "transparent" # cursor: none
    "image:16x16" # cursor: url(16x16 red square)
)
CELL_W=320
CELL_H=135
COLUMNS=6

# The firefox service with FIREFOX_PRIVATE_BROWSING set to VALUE (the shell's
# value wins over .env's), as `docker compose config --format json` gives it,
# in $WORK/compose-VALUE.json, and as the image (first line) and `docker run`
# arguments (one per line) in $WORK/service-args-VALUE.
service_config() {
    FIREFOX_PRIVATE_BROWSING=$1 docker compose -f "$REPO/docker-compose.yml" config \
        --format json >"$WORK/compose-$1.json"
    python3 -I "$E2E_DIR/service_args.py" <"$WORK/compose-$1.json" >"$WORK/service-args-$1"
}
# A group that a run of all the groups started (run_groups) gets that run's
# work directory in E2E_SETUP_DIR. It takes the service's configuration from
# there, which that run printed and checked the image's overlaid files with,
# so every group tests the same configuration, and it does not print or check
# them again.
SETUP_DIR=${E2E_SETUP_DIR:-}
for value in true false yes; do
    if [[ -n "$SETUP_DIR" ]]; then
        cp "$SETUP_DIR/compose-$value.json" "$SETUP_DIR/service-args-$value" "$WORK/"
    else
        service_config "$value"
    fi
done
cp "$WORK/compose-true.json" "$WORK/compose.json"

IMAGE=$(head -n 1 "$WORK/service-args-true")
SERVICE_ARGS=()
while IFS= read -r arg; do
    SERVICE_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args-true")
# What start_firefox_windowed and check_prefs use; scenarios 6 and 10 swap in OFF_ARGS.
FIREFOX_ARGS=("${SERVICE_ARGS[@]}")
OFF_ARGS=()
while IFS= read -r arg; do
    OFF_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args-false")
BAD_ARGS=()
while IFS= read -r arg; do
    BAD_ARGS+=("$arg")
done < <(tail -n +2 "$WORK/service-args-yes")
if [[ -z "$SETUP_DIR" ]]; then
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
fi
NATIVE_CSS_SOURCE="$REPO/config/cursors/native-css"
if [[ " ${SERVICE_ARGS[*]} " != *" $NATIVE_CSS_SOURCE:"* ]]; then
    echo "FAIL: the firefox service does not mount $NATIVE_CSS_SOURCE" >&2
    exit 1
fi

# The firefox service mounts patched copies of some of the image's files over them (the
# overlays tests/image_overlays.py lists: config/novnc/cursor.js and ui.js, and
# config/firefox-services/kill), which would hide any change a new image made to them. The
# image's own files (from a container that is created, never started, so no mount covers them)
# must still be the ones each NAME.patch was made from (config/cursors/README.md).
if [[ -z "$SETUP_DIR" ]]; then
    docker create --name "$CONTAINER-overlays" "$IMAGE" >/dev/null
    OVERLAID=$(python3 -I "$REPO/tests/image_overlays.py" --paths)
    while IFS= read -r path; do
        mkdir -p "$WORK/image-root$(dirname "$path")"
        docker cp -q "$CONTAINER-overlays:$path" "$WORK/image-root$path"
    done <<<"$OVERLAID"
    docker rm -v "$CONTAINER-overlays" >/dev/null
    python3 -I "$REPO/tests/image_overlays.py" "$WORK/image-root"
fi

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

# Starts PROBE_CONTAINER in the network namespace of the test container that
# was just started, with tests/e2e at /e2e and WORK at /out.
start_probe() {
    docker run -d --rm --name "$PROBE_CONTAINER" --network "container:$CONTAINER" \
        -v "$E2E_DIR:/e2e:ro" -v "$WORK:/out" "$PROBE_IMAGE" sleep infinity >/dev/null
}
# probe SCRIPT ARGS...: runs tests/e2e/SCRIPT in PROBE_CONTAINER.
probe() {
    local script=$1
    shift
    docker exec "$PROBE_CONTAINER" python -I "/e2e/$script" "$@"
}

# Starts the test container with the native-css theme from THEME_DIR and waits
# for the test page. Sets WINDOW to Firefox's X window id.
start_firefox() {
    local theme_dir=$1 args=() arg deadline
    for arg in "${SERVICE_ARGS[@]}"; do
        args+=("${arg/#$NATIVE_CSS_SOURCE:/$theme_dir:}")
    done
    docker rm -f -v "$PROBE_CONTAINER" "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$CONTAINER" --network none "${NO_DNS_ARGS[@]}" \
        --shm-size 1g \
        "${args[@]}" \
        -e FF_KIOSK=1 \
        -e FF_OPEN_URL=file:///e2e/cursor-page.html \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        -v "$E2E_DIR/cursor-page.html:/e2e/cursor-page.html:ro" \
        "$IMAGE" >/dev/null
    follow_start_log
    start_probe

    echo "waiting for Firefox to show the test page..."
    deadline=$((SECONDS + 90))
    while ((SECONDS < deadline)); do
        if in_x xdotool search --name 'native cursor e2e' >/dev/null 2>&1; then
            break
        fi
        sleep "$START_POLL_S"
    done
    WINDOW=$(in_x xdotool search --name 'native cursor e2e' 2>/dev/null | head -n 1) ||
        start_failed "the test page"
    stop_following_start_log
    sleep 2 # let the page finish layout
}

# Follows the log of the test container just started into $WORK/start.log, so
# that a start that fails still has its log to show: the containers run with
# --rm, so one whose init stops it is gone, log and all, before the wait for
# its window ends.
follow_start_log() {
    docker logs -f "$CONTAINER" >"$WORK/start.log" 2>&1 &
    START_LOG_PID=$!
}
# Ends follow_start_log once the start has shown its window.
stop_following_start_log() {
    kill "$START_LOG_PID" 2>/dev/null || true
    wait "$START_LOG_PID" 2>/dev/null || true
}
# start_failed WHAT: the start never showed WHAT. Fails as check firefox-start,
# with the end of the container's log, and ends the run with its summary: every
# check after the start needs it (and a run that exited without its summary
# line would be reported as one that stopped, not as a failed check).
start_failed() {
    stop_following_start_log
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf 'FAIL  %-22s Firefox never showed %s within 90 s; the end of the container log:\n' \
        firefox-start "$1"
    tail -n 30 "$WORK/start.log" | sed 's/^/      /'
    summary
}
# end_run LABEL MESSAGE: a step every later check of this run needs failed (a
# helper server that did not start, a window that did not open, a container
# that was not removed). Fails as check LABEL with MESSAGE and ends the run
# with its summary, as start_failed does.
end_run() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf 'FAIL  %-22s %s\n' "$1" "$2"
    summary
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
    summary=$(probe rfb_cursor_probe.py 127.0.0.1 5900 "$x" "$y" "/out/cell$index")
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
# next start if the default changes), or if it is in BUILT_IN_DEFAULTS and
# prefs.js has no line for the pref at all.
FIREFOX_DEFAULT_PREFS="/usr/lib/firefox/defaults/pref /usr/lib/firefox/browser/defaults/preferences"
# Entries equal to a default compiled into Firefox, which no pref file shows.
# browser.privatebrowsing.autostart is false without a user value (measured on
# v26.09.1: no private browsing indicator; scenario 10 checks the effect: a
# cookie and history kept across a restart).
BUILT_IN_DEFAULTS=" browser.privatebrowsing.autostart=false "
# Prints the test container's /config/profile/prefs.js. Firefox saves its prefs
# by writing a new file and renaming it over prefs.js, which it does in the
# first seconds after its window shows. On a /config mounted from the host (as
# scenarios 6 and 10 mount it), a read during that rename finds no file at all
# on OrbStack (in 3000 renames, 2875 of 16818 reads; gaps of 3.8 ms at most,
# and no read of part of a file, measured), so a read that finds none is tried
# again, up to 20 times 0.1 s apart.
read_prefs() {
    local tries=0
    until docker exec "$CONTAINER" cat /config/profile/prefs.js 2>/dev/null; do
        tries=$((tries + 1))
        ((tries < 20)) || return 1
        sleep 0.1
    done
}
check_prefs() {
    local i env name value pref_value line default prefs
    # One read for all the entries (read_prefs), each checked in it.
    if ! prefs=$(read_prefs); then
        checks=$((checks + 1))
        echo "FAIL  prefs.js: the container's /config/profile/prefs.js could not be read"
        failures=$((failures + 1))
        return 0
    fi
    # From the second argument: each entry is the value of the "-e" before it
    # (an index of -1 is an error in bash 3.2, and the last argument in bash 4.3+).
    for ((i = 1; i < ${#FIREFOX_ARGS[@]}; i++)); do
        env=${FIREFOX_ARGS[$i]}
        [[ "${FIREFOX_ARGS[$((i - 1))]}" == "-e" && "$env" == FF_PREF_* ]] || continue
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
        if grep -qxF "$line" <<<"$prefs"; then
            echo "ok    $name -> $line"
        elif docker exec "$CONTAINER" sh -c "grep -qxF -r -e '$default' $FIREFOX_DEFAULT_PREFS"; then
            echo "ok    $name -> the default is the same: $default"
        elif [[ "$BUILT_IN_DEFAULTS" == *" $value "* ]] &&
            ! grep -qF "user_pref(\"${value%%=*}\"," <<<"$prefs"; then
            echo "ok    $name -> no line, Firefox's built-in default is the same: $value"
        else
            echo "FAIL  $name: prefs.js has no line $line"
            failures=$((failures + 1))
        fi
    done
}

# check_cells FIRST LAST: check_cell for the page's cells FIRST to LAST.
check_cells() {
    local i
    for ((i = $1; i <= $2; i++)); do
        check_cell "$i" "${EXPECTED[$i]}"
    done
}

# Scenario 1's shards each read their cells in a container of their own: one
# X display has one pointer, so the cells of one container are read one after
# another.
scenario_1a() {
    echo "== scenario 1a: the theme as committed (prefs, window position, cells 0-12)"
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
    check_cells 0 12
}
scenario_1b() {
    echo "== scenario 1b: the theme as committed (cells 13-25)"
    start_firefox "$NATIVE_CSS_SOURCE"
    check_cells 13 25
}
scenario_1c() {
    echo "== scenario 1c: the theme as committed (cells 26-$((${#EXPECTED[@]} - 1)))"
    start_firefox "$NATIVE_CSS_SOURCE"
    check_cells 26 $((${#EXPECTED[@]} - 1))
}

# Names the theme lacks: GDK tries a legacy name, then left_ptr. "help" has no
# usable legacy name, so it should end at left_ptr, the "default" marker.
# "crosshair" is also a core cursor font glyph, so it should become that 1-bit
# image. "text" stays in the theme as a control. It is read first: the probe
# reports the cursor once it has not changed for 1.5 s, so if Firefox changed
# it later than that, the read would show the cursor of the pointer's previous
# place. Right after the start that is likely "default", which cell 2 expects;
# after cell 8 it is "text".
scenario_2() {
    echo "== scenario 2: theme without help and crosshair (fallback behavior)"
    cp -R "$NATIVE_CSS_SOURCE" "$WORK/reduced-theme"
    rm "$WORK/reduced-theme/cursors/help" "$WORK/reduced-theme/cursors/crosshair"
    start_firefox "$WORK/reduced-theme"
    check_cell 8 "text"      # cursor: text
    check_cell 2 "default"   # cursor: help
    check_cell 7 "image:any" # cursor: crosshair
}

# Starts a normal Firefox window (not kiosk), so the tab strip and toolbar
# exist, on the test page PAGE (blank-page.html by default) and waits until
# its window title contains TITLE. Further arguments go to `docker run`. Sets
# WINDOW to Firefox's X window id. The address bar does not autofill here
# (FF_PREF_NO_URLBAR_AUTOFILL, test only), so a URL type_url types is all it
# holds (see there).
start_firefox_windowed() {
    local page=${1:-blank-page.html} title=${2:-e2e blank page} deadline
    shift $(($# < 2 ? $# : 2))
    docker rm -f -v "$PROBE_CONTAINER" "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --rm --name "$CONTAINER" --network none "${NO_DNS_ARGS[@]}" \
        --shm-size 1g \
        "${FIREFOX_ARGS[@]}" "$@" \
        -e "FF_OPEN_URL=file:///e2e/$page" \
        -e FF_PREF_NO_DATA_BAR=datareporting.policy.dataSubmissionPolicyBypassNotification=true \
        -e FF_PREF_NO_URLBAR_AUTOFILL=browser.urlbar.autoFill=false \
        -v "$E2E_DIR:/e2e:ro" \
        "$IMAGE" >/dev/null
    follow_start_log
    start_probe
    echo "waiting for Firefox to show $page..."
    WINDOW=""
    deadline=$((SECONDS + 90))
    while ((SECONDS < deadline)); do
        WINDOW=$(in_x xdotool search --classname Navigator 2>/dev/null | head -n 1) || true
        if [[ -n "$WINDOW" ]] &&
            [[ "$(in_x xdotool getwindowname "$WINDOW" 2>/dev/null)" == *"$title"* ]]; then
            stop_following_start_log
            return 0
        fi
        sleep "$START_POLL_S"
    done
    start_failed "$page"
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
    summary=$(probe rfb_cursor_probe.py 127.0.0.1 5900 "$x2" "$y2" "/out/$label")
    in_x xdotool mouseup "$button"
    if [[ "$modifier" != none ]]; then
        in_x xdotool keyup "$modifier"
    fi
    in_x xdotool key Escape # closes the context menu a right-button drag opens
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

scenario_3() {
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
}

# Hovers (X,Y) and checks the cursor's classification equals EXPECTED.
check_point() {
    local label=$1 x=$2 y=$3 expected=$4 summary actual
    checks=$((checks + 1))
    summary=$(probe rfb_cursor_probe.py 127.0.0.1 5900 "$x" "$y" "/out/$label")
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
scenario_4() {
    echo "== scenario 4: Openbox's own cursors on a decorated window are recognized"
    in_x xdotool windowactivate --sync "$WINDOW" key ctrl+shift+o
    LIBRARY=""
    for _ in $(seq 1 20); do
        LIBRARY=$(in_x xdotool search --name '^Library$' 2>/dev/null | head -n 1) || true
        [[ -n "$LIBRARY" ]] && break
        sleep 0.5
    done
    if [[ -z "$LIBRARY" ]]; then
        end_run library-window "the Library window did not open (Ctrl+Shift+O)"
    fi
    sleep 2
    # Client area position and size; Openbox's frame surrounds it.
    read -r lib_x lib_y lib_w lib_h < <(in_x xdotool getwindowgeometry "$LIBRARY" |
        sed -n -e 's/.*Position: \([0-9]*\),\([0-9]*\).*/\1 \2/p' \
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
}

# Prints the title of the page window WIN (default WINDOW) shows: its window
# title without the " — Mozilla Firefox" suffix (" — Mozilla Firefox Private
# Browsing" in a private window while private-only browsing is off), or "" for
# a page without a title: shown_title [WIN].
shown_title() {
    local name
    name=$(in_x xdotool getwindowname "${1:-$WINDOW}") || return 1
    name=${name% — Mozilla Firefox Private Browsing}
    name=${name% — Mozilla Firefox}
    if [[ "$name" == "Mozilla Firefox" || "$name" == "Mozilla Firefox Private Browsing" ]]; then
        name=""
    fi
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

# wait_title_in WIN PREFIX: wait_title for window WIN, without showing it.
# Fails at once if WIN is "" (no such window).
wait_title_in() {
    local saved=$WINDOW status=0
    [[ -n "$1" ]] || return 1
    WINDOW=$1
    wait_title "$2" >/dev/null || status=$?
    WINDOW=$saved
    return "$status"
}

# Prints the time in milliseconds: from bash 5's EPOCHREALTIME, or from perl
# under macOS's bash 3.2, which has no clock finer than a second.
now_ms() {
    local now=${EPOCHREALTIME:-}
    if [[ -n "$now" ]]; then
        now=${now/[.,]/}
        echo $((10#${now:0:${#now}-3}))
    else
        perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
    fi
}

# The absence checks wait for a change that must not come: check_tabs for a
# second tab after Ctrl+PageDown in a window of one tab, check_windows for
# anything an action that must change nothing would show (another window, or
# its tab moved in). How long a change of the same kind takes when it must
# come is measured as the run goes: "tab", a tab shown after the key that
# switches to it (check_tabs); "window", what an action shows (check_windows'
# SHOWS, a new private window listed, open_then_load's new tab) after the
# action. record_latency KIND MS keeps the longest of each in a file in WORK,
# so that checks run in a subshell ($(...)) count too.
record_latency() {
    local file=$WORK/latency-$1 longest=0
    [[ ! -f "$file" ]] || longest=$(<"$file")
    ((${2} <= longest)) || echo "$2" >"$file"
}
# Prints the longest latency of KIND measured so far in this run, in ms (0
# before the first).
longest_latency() {
    if [[ -f "$WORK/latency-$1" ]]; then
        cat "$WORK/latency-$1"
    else
        echo 0
    fi
}
# Prints how long, in milliseconds, an absence check of KIND waits: twice the
# longest latency of that kind measured so far in this run, at least
# ABSENCE_MIN_MS and at most ABSENCE_MAX_MS. Measured on this suite: a tab
# shows at the first read (under 0.1 s) at light load, within 0.3 s with 16
# Firefox containers at once, and a new window is listed within 0.15 s and
# 0.45 s (docs/agents_output/analysis/test-speed-60s-e2e-sc5-sc10.md): the
# floor alone is more than twice the longest of either, even before this run
# has measured one. The ceiling is the fixed wait these checks had before they
# were sized: once, with every suite running at once, one action took 1695 ms
# to show its change, which made each later window absence wait 3.39 s
# (docs/agents_output/fixes/e2e-shards-60s.md). A change that comes later than
# the wait passes that check, but the next check that reads the windows or
# tabs compares all of them and fails.
ABSENCE_MIN_MS=1000
ABSENCE_MAX_MS=2000
absence_ms() {
    local ms
    ms=$((2 * $(longest_latency "$1")))
    ((ms >= ABSENCE_MIN_MS)) || ms=$ABSENCE_MIN_MS
    ((ms <= ABSENCE_MAX_MS)) || ms=$ABSENCE_MAX_MS
    echo "$ms"
}
# Prints absence_ms in seconds, for sleep: absence_wait KIND.
absence_wait() {
    local ms
    ms=$(absence_ms "$1")
    printf '%d.%03d\n' $((ms / 1000)) $((ms % 1000))
}

# Prints the longest latency of KIND for summary: "longest N ms", with what
# the ceiling cut if twice that is more than ABSENCE_MAX_MS, or "none
# measured" (the wait is then ABSENCE_MIN_MS).
latency_note() {
    local longest
    if [[ -f "$WORK/latency-$1" ]]; then
        longest=$(longest_latency "$1")
        if ((2 * longest > ABSENCE_MAX_MS)); then
            echo "longest $longest ms; twice that, $((2 * longest)) ms, capped at $ABSENCE_MAX_MS ms"
        else
            echo "longest $longest ms"
        fi
    else
        echo "none measured"
    fi
}

# switch_tab KEY PREFIX: presses KEY, which shows another tab, and waits until
# the page shown has a title that starts with PREFIX (wait_title); prints that
# title. The time from the key to the title is a "tab" latency.
switch_tab() {
    local started title
    started=$(now_ms)
    in_x xdotool key "$1" || return 1
    title=$(wait_title "$2") || return 1
    record_latency tab "$(($(now_ms) - started))"
    printf '%s\n' "$title"
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
# page without a title, such as a new tab; "e2e-blank" is blank-page.html).
tab_prefix() {
    if [[ "$1" == untitled ]]; then
        echo ""
    elif [[ "$1" == e2e-blank ]]; then
        echo "e2e blank page"
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
# nothing can change, so Ctrl+PageDown gets absence_wait's "tab" time to show
# a second tab. Prints what differs and returns 1 on a mismatch.
check_tabs() {
    local names=() titles=() n k title
    read -r -a names <<<"$1"
    n=${#names[@]}
    if ((n == 1)); then
        if ! title=$(wait_title "$(tab_prefix "${names[0]}")"); then
            echo "the window shows '$(shown_title)', not ${names[0]}"
            return 1
        fi
        in_x xdotool key ctrl+Next sleep "$(absence_wait tab)" || return 1
        if [[ "$(shown_title)" != "$title" ]]; then
            echo "a second tab exists: '$(shown_title)'"
            return 1
        fi
        return 0
    fi
    # Start from the last tab, so Alt+1 must change the page shown.
    if ! switch_tab alt+9 "$(tab_prefix "${names[n - 1]}")" >/dev/null; then
        echo "the last tab is '$(shown_title)', not ${names[n - 1]}"
        return 1
    fi
    for ((k = 1; k <= n; k++)); do
        if ! title=$(switch_tab "alt+$k" "$(tab_prefix "${names[k - 1]}")"); then
            echo "tab $k is '$(shown_title)', not ${names[k - 1]}"
            return 1
        fi
        titles+=("$title")
    done
    # Tab N must be the last tab: the next one is the first again.
    if ! switch_tab ctrl+Next "${titles[0]}" >/dev/null; then
        echo "after tab $n comes '$(shown_title)', not tab 1"
        return 1
    fi
    switch_tab "alt+$n" "${titles[n - 1]}" >/dev/null
}

# The private window, once one is open (scenario 10), or "".
PWINDOW=""

# in_window WIN COMMAND...: runs COMMAND with WINDOW set to WIN, after
# activating WIN so that keys go to it; WINDOW is the same again afterwards.
# Fails without running COMMAND if WIN is "" (no such window).
in_window() {
    local saved=$WINDOW status=0
    [[ -n "$1" ]] || return 1
    WINDOW=$1
    shift
    in_x xdotool windowactivate --sync "$WINDOW" >/dev/null 2>&1 || true
    "$@" || status=$?
    WINDOW=$saved
    return "$status"
}

# Waits up to 15 s for a browser window other than WINDOW (the private one,
# just opened) and sets PWINDOW to it; fails if none comes. The time it takes
# is a "window" latency.
find_private_window() {
    local deadline=$((SECONDS + 15)) started
    started=$(now_ms)
    PWINDOW=""
    while :; do
        PWINDOW=$(tr ' ' '\n' <<<"$(browser_windows || true)" | grep -vx "$WINDOW" | head -n 1) ||
            PWINDOW=""
        if [[ -n "$PWINDOW" ]]; then
            record_latency window "$(($(now_ms) - started))"
            return 0
        fi
        ((SECONDS < deadline)) || return 1
        sleep 0.2
    done
}

# Prints the window ids in $1 (space-separated) sorted, space-separated.
sorted_ids() {
    tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort | paste -sd ' ' -
}

# Prints what is wrong with window WIN's size: it must be at 0,0 and cover the
# display, and Openbox must have it maximized (_NET_WM_STATE); nothing if right.
window_size_problem() {
    local geometry state
    geometry=$(in_x xdotool getwindowgeometry "$1" 2>/dev/null | tr -s ' ' | paste -sd ' ' -) || true
    state=$(in_x obxprop --id "$1" 2>/dev/null | grep '^_NET_WM_STATE(ATOM)') || true
    if [[ "$geometry" != *"Position: 0,0 "*"Geometry: $(display_size)"* ]] ||
        [[ "$state" != *_NET_WM_STATE_MAXIMIZED_VERT* || "$state" != *_NET_WM_STATE_MAXIMIZED_HORZ* ]]; then
        echo "window $1: $geometry; $state"
    fi
}

# check_windows LABEL TABS PRIVATE_TABS WHERE SHOWS ACTION...
# Runs ACTION, then checks that Firefox has exactly the browser windows it
# should: the original one (WINDOW) and, unless PRIVATE_TABS is "-", one
# private window (PWINDOW; the first check that expects it finds it, as the
# window that is not WINDOW), no other. Each must be maximized at 0,0 over the
# whole display; the private one's title must say it is private and WINDOW's
# must not. The container must still be running (closing Firefox's last
# window stops it). WINDOW must have exactly the tabs TABS and the private
# window PRIVATE_TABS (see check_tabs). SHOWS is the page ACTION must show in
# the WHERE ("normal" or "private") window, which the check waits for, or "-"
# if ACTION should change nothing: there is nothing to wait for then, so the
# check gives another window absence_wait's "window" time to appear. A failed
# ACTION fails.
check_windows() {
    local label=$1 tabs=$2 private_tabs=$3 where=$4 shows=$5 problem="" want windows window
    local deadline target title started
    shift 5
    checks=$((checks + 1))
    if ! "$@"; then
        problem="the action failed: $*"
    fi
    if [[ -z "$problem" && "$private_tabs" != - && -z "$PWINDOW" ]] && ! find_private_window; then
        problem="no second (private) window opened"
    fi
    want=$WINDOW
    [[ "$private_tabs" == - ]] || want="$WINDOW $PWINDOW"
    want=$(sorted_ids "$want")
    target=$WINDOW
    [[ "$where" == normal ]] || target=$PWINDOW
    started=$(now_ms)
    if [[ -n "$problem" ]]; then
        :
    elif [[ "$shows" == - ]]; then
        sleep "$(absence_wait window)"
    elif ! in_window "$target" wait_title "$(tab_prefix "$shows")" >/dev/null; then
        problem="the $where window shows '$(in_window "$target" shown_title)', not $shows"
    else
        record_latency window "$(($(now_ms) - started))"
        # A window may still be closing after its tabs moved.
        deadline=$((SECONDS + 15))
        until [[ "$(sorted_ids "$(browser_windows || true)")" == "$want" ]] ||
            ((SECONDS >= deadline)); do
            sleep 0.2
        done
    fi
    if [[ -z "$problem" ]]; then
        windows=$(sorted_ids "$(browser_windows || true)")
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]]; then
            problem="the container stopped (Firefox exited)"
        elif [[ "$windows" != "$want" ]]; then
            problem="windows: $windows (want $want)"
        fi
    fi
    if [[ -z "$problem" ]]; then
        for window in $want; do
            problem+=$(window_size_problem "$window")
        done
    fi
    if [[ -z "$problem" && "$private_tabs" != - ]]; then
        title=$(in_x xdotool getwindowname "$PWINDOW" 2>/dev/null) || true
        if [[ "$title" != *"Mozilla Firefox Private Browsing" ]]; then
            problem="the second window is not private: '$title'"
        elif [[ "$(in_x xdotool getwindowname "$WINDOW" 2>/dev/null || true)" == *"Private Browsing" ]]; then
            problem="the first window is private"
        fi
    fi
    if [[ -z "$problem" ]] && ! problem=$(in_window "$WINDOW" check_tabs "$tabs"); then
        problem="tabs: $problem"
    fi
    if [[ -z "$problem" && "$private_tabs" != - ]] &&
        ! problem=$(in_window "$PWINDOW" check_tabs "$private_tabs"); then
        problem="private tabs: $problem"
    fi
    in_x xdotool windowactivate --sync "$WINDOW" >/dev/null 2>&1 || true
    if [[ -z "$problem" ]]; then
        if [[ "$private_tabs" == - ]]; then
            printf 'ok    %-22s tabs: %s\n' "$label" "$tabs"
        else
            printf 'ok    %-22s tabs: %s | private: %s\n' "$label" "$tabs" "$private_tabs"
        fi
    else
        printf 'FAIL  %-22s %s\n' "$label" "$problem"
        failures=$((failures + 1))
    fi
}

# Prints the id of the window at the top of Openbox's stacking order.
stack_top() {
    local stacking
    stacking=$(in_x obxprop --root _NET_CLIENT_LIST_STACKING 2>/dev/null) || return 1
    stacking=${stacking##*= }
    printf '%s\n' "${stacking##*, }"
}

# Succeeds if a menu is open: a visible popup-menu window (Firefox opens each
# menu as one).
menu_open() {
    local window properties
    for window in $(in_x xdotool search --onlyvisible --name . 2>/dev/null || true); do
        properties=$(in_x obxprop --id "$window" 2>/dev/null) || continue
        if grep -q '_NET_WM_WINDOW_TYPE_POPUP_MENU' <<<"$properties"; then
            return 0
        fi
    done
    return 1
}

# check_shown LABEL WIN ACTION...: runs ACTION, then checks that window WIN is
# shown: X's active window and the top of Openbox's stack (within 10 s), that
# Firefox still has exactly WINDOW and PWINDOW, both maximized, and that the
# container still runs.
check_shown() {
    local label=$1 want=$2 problem="" active="" top="" windows deadline window
    shift 2
    checks=$((checks + 1))
    if ! "$@"; then
        problem="the action failed: $*"
    else
        deadline=$((SECONDS + 10))
        while :; do
            active=$(in_x xdotool getactivewindow 2>/dev/null) || active=""
            top=$(stack_top) || top=""
            if [[ "$active" == "$want" && "$top" == "$want" ]] || ((SECONDS >= deadline)); then
                break
            fi
            sleep 0.2
        done
        windows=$(sorted_ids "$(browser_windows || true)")
        if [[ "$active" != "$want" || "$top" != "$want" ]]; then
            problem="active window $active, top $top (want $want)"
        elif [[ "$windows" != "$(sorted_ids "$WINDOW $PWINDOW")" ]]; then
            problem="windows: $windows (want $WINDOW $PWINDOW)"
        elif [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]]; then
            problem="the container stopped (Firefox exited)"
        else
            for window in $windows; do
                problem+=$(window_size_problem "$window")
            done
        fi
    fi
    if [[ -z "$problem" ]]; then
        printf 'ok    %-22s shown: %s\n' "$label" "$want"
    else
        printf 'FAIL  %-22s %s\n' "$label" "$problem"
        failures=$((failures + 1))
    fi
}

# check_window_menu LABEL COUNT: the Window menu (Alt+W) of the active window
# lists COUNT windows, numbered from 1 (access keys 1, 2, ...): it opens, has
# no item COUNT+1 (the key leaves the menu open), and item 1, the oldest
# window, WINDOW, shows that window.
check_window_menu() {
    local label=$1 count=$2 problem=""
    checks=$((checks + 1))
    in_x xdotool key alt+w sleep 1
    if ! menu_open; then
        problem="Alt+W opened no menu"
        # Alt+W may have left the menu bar active, which would take the next keys.
        in_x xdotool key Escape sleep 0.5 key Escape
    else
        in_x xdotool key "$((count + 1))" sleep 1
        if ! menu_open; then
            problem="the menu has an item $((count + 1))"
        else
            in_x xdotool key Escape sleep 0.5 key Escape sleep 0.5
            in_x xdotool key alt+w sleep 1 key 1 sleep 1
            if menu_open; then
                problem="the menu has no item 1"
                in_x xdotool key Escape sleep 0.5 key Escape
            elif [[ "$(in_x xdotool getactivewindow 2>/dev/null || true)" != "$WINDOW" ]]; then
                problem="item 1 did not show the first window"
            fi
        fi
    fi
    if [[ -z "$problem" ]]; then
        printf 'ok    %-22s %s window(s) listed\n' "$label" "$count"
    else
        printf 'FAIL  %-22s %s\n' "$label" "$problem"
        failures=$((failures + 1))
    fi
}

# close_window WIN XDOTOOL_ARGS...: shows window WIN, runs xdotool with
# XDOTOOL_ARGS (a way to close it), and waits up to 10 s for WIN to be gone.
close_window() {
    local window=$1 deadline=$((SECONDS + 10))
    shift
    in_x xdotool windowactivate --sync "$window" || return 1
    in_x xdotool "$@" || return 1
    while [[ " $(browser_windows || true) " == *" $window "* ]]; do
        ((SECONDS < deadline)) || return 1
        sleep 0.2
    done
}

# check_single_window LABEL TABS SHOWS ACTION...: check_windows with no
# private window: Firefox has exactly one browser window, WINDOW.
check_single_window() {
    local label=$1 tabs=$2 shows=$3
    shift 3
    check_windows "$label" "$tabs" - normal "$shows" "$@"
}

# Counts the pixels within TOLERANCE of COLOR (RRGGBB) in the screen region
# X Y W H, read over VNC; prints rfb_color_probe.py's JSON summary.
count_color() {
    probe rfb_color_probe.py 127.0.0.1 5900 "$@"
}

# Firefox's own "Private browsing" indicator (userChrome.css shows it with
# permanent private browsing) at the end of the tab strip. Its mask icon has a
# fixed #8000D7 fill; measured on v26.09.1: about 90 such pixels in the 44px
# strip, and none with private browsing off. Reads the strip until the icon
# shows or WAIT_S (default 15) seconds pass (it may still be drawing), and sets
# INDICATOR to the last summary and INDICATOR_PIXELS to its count:
# read_indicator [WAIT_S]. INDICATOR_SHOW_S is the longest it took to show so
# far in this run (whole seconds), or "" before it has shown.
INDICATOR_MIN=50
INDICATOR_SHOW_S=""
read_indicator() {
    local start=$SECONDS deadline=$((SECONDS + ${1:-15}))
    while :; do
        INDICATOR=$(count_color 0 0 "$DISPLAY_W" 44 8000d7 16)
        INDICATOR_PIXELS=$(sed -n 's/.*"matches": \([0-9]*\).*/\1/p' <<<"$INDICATOR")
        INDICATOR_PIXELS=${INDICATOR_PIXELS:-0}
        if ((INDICATOR_PIXELS >= INDICATOR_MIN)); then
            if [[ -z "$INDICATOR_SHOW_S" ]] || ((SECONDS - start > INDICATOR_SHOW_S)); then
                INDICATOR_SHOW_S=$((SECONDS - start))
            fi
            return 0
        fi
        ((SECONDS < deadline)) || return 0
        sleep 1
    done
}
# How long to read the strip to see that the icon does not show: three times
# the longest it took to show in this run, at least 3 s, at most 15 s (15 s
# before it has shown).
indicator_absent_wait() {
    local wait=15
    if [[ -n "$INDICATOR_SHOW_S" ]]; then
        wait=$((INDICATOR_SHOW_S * 3))
        ((wait >= 3)) || wait=3
        ((wait <= 15)) || wait=15
    fi
    echo "$wait"
}

# Prints the process id of Firefox's main process (not a content process), or
# nothing if Firefox is not running. awk reads to the end: stopping at the
# first match could leave ps writing into a closed pipe (SIGPIPE), which fails
# the pipeline under pipefail and stops this script.
firefox_pid() {
    docker exec "$CONTAINER" ps -o pid,args 2>/dev/null |
        awk '$2 == "/usr/lib/firefox/firefox" && !/-contentproc/ && !found { print $1; found = 1 }'
}

# Prints what the test container shows, for a failed check LABEL: Firefox's
# processes, the visible windows with their names, and the end of Firefox's
# own log. With E2E_ARTIFACTS set to a directory, also saves a screenshot
# there as LABEL.png.
failure_details() {
    local window
    echo "      Firefox processes: $(docker exec "$CONTAINER" ps -o pid,args 2>/dev/null |
        awk '$2 == "/usr/lib/firefox/firefox" { print $1 (/-contentproc/ ? "c" : "") }' |
        paste -sd ' ' -)"
    for window in $(in_x xdotool search --onlyvisible --name . 2>/dev/null || true); do
        echo "      window $window: $(in_x xdotool getwindowname "$window" 2>/dev/null || true)"
    done
    docker exec "$CONTAINER" tail -n 5 /config/log/firefox/error.log 2>/dev/null |
        sed 's/^/      log: /' || true
    if [[ -n "${E2E_ARTIFACTS:-}" ]]; then
        mkdir -p "$E2E_ARTIFACTS"
        docker run --rm --network "container:$CONTAINER" -v "$E2E_DIR:/e2e:ro" \
            -v "$E2E_ARTIFACTS:/out" "$PROBE_IMAGE" python -I /e2e/rfb_color_probe.py \
            127.0.0.1 5900 0 0 "$DISPLAY_W" "$DISPLAY_H" 000000 0 "/out/$1.png" >/dev/null ||
            true
    fi
}

# check_restarted LABEL KIND TABS ACTION...: runs ACTION, which must make
# Firefox quit, and checks that the image starts it again in the same running
# container (KEEP_APP_RUNNING=1): a new Firefox process within 60 s, with one
# browser window, maximized, with exactly the tabs TABS (see check_tabs).
# KIND "private": permanent private browsing, shown by the private browsing
# indicator (a permanently private window's title does not say it is private);
# "normal": a window whose title does not say it is private. WINDOW is the new
# window afterwards, and there is no private window.
check_restarted() {
    local label=$1 kind=$2 tabs=$3 problem="" old_pid new_pid="" started windows title
    local deadline start=$SECONDS
    shift 3
    checks=$((checks + 1))
    old_pid=$(firefox_pid)
    started=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER")
    if ! "$@"; then
        problem="the action failed: $*"
    else
        deadline=$((SECONDS + 60))
        while ((SECONDS < deadline)); do
            new_pid=$(firefox_pid) || new_pid=""
            windows=$(browser_windows || true)
            if [[ -n "$new_pid" && "$new_pid" != "$old_pid" && -n "$windows" ]]; then
                break
            fi
            sleep 0.2
        done
        if [[ -z "$new_pid" || "$new_pid" == "$old_pid" ]]; then
            problem="Firefox (pid $old_pid) is not a new process: '$new_pid'"
        elif [[ "$(docker inspect -f '{{.State.Running}} {{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)" != "true $started" ]]; then
            problem="the container stopped or restarted"
        elif [[ "$windows" == *" "* || -z "$windows" ]]; then
            problem="browser windows: '$windows' (want one)"
        fi
    fi
    if [[ -z "$problem" ]]; then
        WINDOW=$windows
        PWINDOW=""
        problem=$(window_size_problem "$WINDOW")
    fi
    if [[ -z "$problem" ]]; then
        title=$(in_x xdotool getwindowname "$WINDOW" 2>/dev/null) || true
        if [[ "$kind" == private ]]; then
            read_indicator
            if ((INDICATOR_PIXELS < INDICATOR_MIN)); then
                problem="no private browsing indicator: $INDICATOR"
            fi
        elif [[ "$title" == *"Private Browsing" ]]; then
            problem="the window is private: '$title'"
        fi
    fi
    if [[ -z "$problem" ]] && ! problem=$(in_window "$WINDOW" check_tabs "$tabs"); then
        problem="tabs: $problem"
    fi
    if [[ -z "$problem" ]]; then
        printf 'ok    %-22s restarted in %s s (pid %s, was %s), tabs: %s\n' "$label" \
            "$((SECONDS - start))" "$new_pid" "$old_pid" "$tabs"
    else
        printf 'FAIL  %-22s %s\n' "$label" "$problem"
        failure_details "$label"
        failures=$((failures + 1))
    fi
}

# check_not_restarted LABEL TABS ACTION...: check_single_window with nothing
# shown, and Firefox must still be the same process.
check_not_restarted() {
    local label=$1 tabs=$2 old_pid new_pid
    shift 2
    old_pid=$(firefox_pid)
    check_single_window "$label" "$tabs" - "$@"
    checks=$((checks + 1))
    new_pid=$(firefox_pid)
    if [[ -n "$old_pid" && "$new_pid" == "$old_pid" ]]; then
        printf 'ok    %-22s Firefox still pid %s\n' "$label-same" "$old_pid"
    else
        printf 'FAIL  %-22s Firefox pid %s, was %s\n' "$label-same" "${new_pid:-(none)}" "$old_pid"
        failures=$((failures + 1))
    fi
}

# Opens Firefox's main menu (the ☰ button at the right end of the toolbar) and
# chooses its last item, Quit & Restart (Up from the menu's start wraps to it),
# then runs xdotool with any arguments given.
appmenu_last_item() {
    in_x xdotool mousemove "$((DISPLAY_W - 25))" 63 click 1 sleep 1.5 key Up sleep 0.5 key Return \
        "$@"
}

# check_no_window_menu LABEL: Alt+W opens no menu (the Window menu's access
# key); Escape twice leaves the menu bar if Alt activated it.
check_no_window_menu() {
    checks=$((checks + 1))
    in_x xdotool key alt+w sleep 1
    if menu_open; then
        printf 'FAIL  %-22s Alt+W opened a menu\n' "$1"
        failures=$((failures + 1))
    else
        printf 'ok    %-22s Alt+W opens no menu\n' "$1"
    fi
    in_x xdotool key Escape sleep 0.5 key Escape sleep 0.5
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

# Asks the running Firefox, as a second `firefox --private-window` would, for a
# private window showing single-window-page.html#NAME, as a toolbar button or
# an extension might. The command needs Firefox's own environment to reach the
# running instance (its D-Bus session and runtime directory); it returns once
# the request is handed over.
open_private_window() {
    docker exec -u 1000:1000 -e DISPLAY=:0 -e HOME=/config \
        -e DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus.base -e XDG_RUNTIME_DIR=/tmp/run/user/app \
        -e XDG_CONFIG_HOME=/config/xdg/config -e XDG_CACHE_HOME=/config/xdg/cache \
        -e XDG_DATA_HOME=/config/xdg/data -e XDG_STATE_HOME=/config/xdg/state \
        "$CONTAINER" timeout 30 /usr/lib/firefox/firefox --profile /config/profile \
        --private-window "file:///e2e/single-window-page.html#$1" >/dev/null 2>&1
}

# The address bar's row: the middle of the toolbar, 63 px from the top (the ☰
# button appmenu_last_item clicks is on it); at mid-width the bar is there at
# any display size.
URLBAR_Y=63
# type_url URL [XDOTOOL_ARGS...]: runs xdotool with XDOTOOL_ARGS, then types
# URL into the address bar of the window shown, as a person would, and presses
# Return. It clicks the bar, then Ctrl+A selects all it holds, which the URL
# replaces. Ctrl+L is not used: while a page has the focus, Firefox hands Ctrl+L
# to the page's process first and focuses the bar only when that process
# answers, so under load the keys typed next went to the page (where "/" opens
# Quick Find, which then took the rest). A click on the bar is handled at once,
# before the keys after it. Focusing the bar can also rerun a search it still
# holds (under load, Firefox sometimes keeps the address typed for the last
# page after that page has loaded); with autofill, that search's first result
# moved the caret to the end of the bar whenever it came, and the URL was
# appended to the old one. start_firefox_windowed turns autofill off.
# docs/agents_output/debugging/e2e-save-as-cascade.md
type_url() {
    local url=$1
    shift
    in_x xdotool "$@" mousemove "$((DISPLAY_W / 2))" "$URLBAR_Y" click 1 key ctrl+a || return 1
    in_x xdotool type --delay 5 "$url" || return 1
    in_x xdotool key Return
}

# open_then_load NAME WIN XDOTOOL_ARGS...: runs xdotool with XDOTOOL_ARGS (keys
# that open a new window or tab), waits up to 15 s until window WIN, where the
# new tab must end up (single-window.cfg moves a later window's tabs into the
# first window of its kind), is X's active window and shows a new tab, then
# loads single-window-page.html#NAME in it, typed into the address bar, so the
# new tab has a name (a new tab's own title is "" or "New Tab", depending on
# when it is read). Fails if WIN does not show a new tab. Typing before then
# could go to the new window, before its tab moves.
open_then_load() {
    local name=$1 win=$2 deadline started title
    shift 2
    [[ -n "$win" ]] || return 1
    in_x xdotool "$@" || return 1
    started=$(now_ms)
    deadline=$((SECONDS + 15))
    until [[ "$(in_x xdotool getactivewindow 2>/dev/null || true)" == "$win" ]] &&
        title=$(shown_title "$win") && [[ -z "$title" || "$title" == "New Tab" ]]; do
        ((SECONDS < deadline)) || return 1
        sleep 0.2
    done
    record_latency window "$(($(now_ms) - started))"
    type_url "file:///e2e/single-window-page.html#$name"
}

# Points on single-window-page.html (scenarios 5 and 10). The first tab's
# handle is at (100,20) and the second's at (420,20) at any display size (tabs
# start at the left and have a fixed width). Tabs are dropped into the right
# and left parts of the page. The page is five bands, each a fifth of its
# height (single-window-page.html); these are their middles.
drop_right_x=$((DISPLAY_W * 3 / 4))
drop_right_y=$((DISPLAY_H * 5 / 9))
drop_left_x=$((DISPLAY_W / 8))
drop_left_y=$((DISPLAY_H * 2 / 3))
link_y=$((DISPLAY_H * 1 / 10))
popup_y=$((DISPLAY_H * 3 / 10))
popup_plain_y=$((DISPLAY_H * 5 / 10))
blank_y=$((DISPLAY_H * 7 / 10))
context_link_y=$((DISPLAY_H * 9 / 10))

# Firefox keeps one window of each kind here, and with private-only browsing
# every window is private, so there is one: dropping a tab outside the tab
# strip must not un-maximize the window or open a new one, Ctrl+N must not open
# one, Ctrl+Shift+P, links and pop-ups that ask for a new window must open as
# tabs in it (config/firefox-autoconfig/single-window.cfg and the FF_PREF_*
# entries). With only one window, there is no Window menu, no Ctrl+` and no
# Close Window. Quit & Restart (Ctrl+Q, the File and main menus) asks first,
# then Firefox quits and the image starts it again in the same container
# (KEEP_APP_RUNNING=1); the container's shutdown key (Ctrl+Alt+Shift+Q, which
# config/firefox-services/kill presses) quits without asking.
# Ctrl+T, Ctrl+W and a tab dragged along the tab strip are controls: they must
# change the tabs, which shows the keys and drags reach Firefox.
# Each shard starts a fresh container on single-window-page.html, so it has
# one tab, main: what the checks before 5b and 5d also leave (5c makes the new
# tab its checks start from, 5e the tabs 5b's checks leave).
start_single_window() {
    start_firefox_windowed single-window-page.html "sw:main "
    in_x xdotool windowactivate --sync "$WINDOW"
}
scenario_5a() {
    echo "== scenario 5a: Firefox stays one maximized window (the only tab, new-window keys)"
    start_single_window
    check_single_window only-tab-dragged-down main - drag 100 20 "$drop_right_x" "$drop_right_y"
    check_single_window only-tab-dragged-left main - drag 100 20 "$drop_left_x" "$drop_left_y"
    check_single_window ctrl-n main - in_x xdotool key ctrl+n
    # A new private window: private like every window here, so its tab moves in.
    check_single_window ctrl-shift-p "main ctrl-shift-p" ctrl-shift-p \
        open_then_load ctrl-shift-p "$WINDOW" key ctrl+shift+p
    check_single_window ctrl-w-new-tab main main in_x xdotool key ctrl+w
    check_single_window ctrl-t "main untitled" untitled in_x xdotool key ctrl+t
    check_single_window ctrl-w main main in_x xdotool key ctrl+w
}
# The tabs scenario 5b's checks leave, in order, the last one shown.
SC5_TABS="shift-click main popup popup-plain blank private"
# A tab dragged along the strip takes its new place after the drop, not at
# it: measured, 0.44-0.59 s after the drag ended; a walk of the tabs before
# then finds the old order. wait_last_tab NAME waits up to 15 s until WINDOW's
# last tab (Alt+9, which leaves it shown) is page NAME (see tab_prefix), and
# fails if it is not by then.
wait_last_tab() {
    local prefix title deadline=$((SECONDS + 15))
    prefix=$(tab_prefix "$1")
    until in_x xdotool key alt+9 sleep 0.2 && title=$(shown_title) &&
        { [[ -z "$prefix" && -z "$title" ]] || [[ -n "$prefix" && "$title" == "$prefix"* ]]; }; do
        ((SECONDS < deadline)) || return 1
    done
}
# drag_to_last NAME X Y X2 Y2: drags a tab along the strip (drag) to the end,
# where it is page NAME, and gives it up to 15 s to take its place there
# (wait_last_tab), for a check: if it does not, the check's own reads of the
# tab shown and of every tab find the order it has.
drag_to_last() {
    local name=$1
    shift
    drag "$@" || return 1
    wait_last_tab "$name" || true
}
# tabs_become TABS COMMAND...: runs COMMAND, which reorders WINDOW's tabs,
# waits until its last tab is the last of TABS (wait_last_tab), then checks
# that it has exactly the tabs TABS (check_tabs), for a setup step.
tabs_become() {
    local tabs=$1 names=()
    shift
    read -r -a names <<<"$tabs"
    "$@" || return 1
    wait_last_tab "${names[${#names[@]} - 1]}" || return 1
    check_tabs "$tabs"
}
scenario_5b() {
    echo "== scenario 5b: Firefox stays one maximized window (links, tab drags, pop-ups, another private window)"
    start_single_window
    # Opens a new window; single-window.cfg moves its tab into the first window.
    check_single_window shift-click "main shift-click" shift-click \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$link_y" keydown shift click 1 keyup shift
    check_single_window tab-moved-along-strip "shift-click main" main \
        drag_to_last main 100 20 420 20
    check_single_window second-tab-torn-off "shift-click main" - \
        drag 100 20 "$drop_right_x" "$drop_right_y"
    # Pop-ups: window.open() with a size asks for a 400x300 pop-up window, one
    # without features and a target="_blank" link for a new window or tab.
    check_single_window popup "shift-click main popup" popup \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_y" click 1
    check_single_window popup-plain "shift-click main popup popup-plain" popup-plain \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_plain_y" click 1
    check_single_window target-blank "shift-click main popup popup-plain blank" blank \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$blank_y" click 1
    # Another private window (here every window is private): its tab moves in too.
    check_single_window private-window "$SC5_TABS" private open_private_window private
}
scenario_5e() {
    echo "== scenario 5e: Firefox stays one maximized window (no Window menu, no Close Window, closing every tab)"
    start_single_window
    # The tabs 5b's checks leave, made with the same actions: the Shift+clicked
    # link, the first tab dragged after it, the three pop-ups (each clicked on
    # the page shown, the tab before it), another private window.
    setup_bands sw-band shift-click || return 0
    setup_step sw-tab-moved "the first tab dragged after the second (tabs shift-click main)" \
        tabs_become "shift-click main" drag 100 20 420 20 || return 0
    setup_bands sw-band popup popup-plain blank || return 0
    setup_step sw-private-window "another private window's tab" \
        tab_shows "$WINDOW" private open_private_window private || return 0
    sw_tabs=$SC5_TABS
    # No Window menu, and Ctrl+` does nothing.
    check_no_window_menu no-window-menu
    check_single_window ctrl-grave "$sw_tabs" - in_x xdotool key ctrl+grave
    # No Close Window: Ctrl+Shift+W and File > Close Window (access key D) do
    # nothing; Escape closes a menu the missing item leaves open.
    check_not_restarted ctrl-shift-w "$sw_tabs" in_x xdotool key ctrl+shift+w
    check_not_restarted file-close-window "$sw_tabs" \
        in_x xdotool key alt+f sleep 1 key d sleep 1 key Escape sleep 0.5 key Escape
    # Closing the last tab must leave the window open with a new tab: that is
    # browser.tabs.closeWindowWithLastTab=false (FF_PREF_KEEP_WINDOW_WITH_LAST_TAB).
    check_single_window ctrl-w-every-tab untitled untitled \
        close_tabs blank popup-plain popup main shift-click untitled
}
# Quit & Restart asks first: Escape answers Cancel, Return Quit & Restart. The
# new Firefox opens FF_OPEN_URL's page (single-window-page.html) and nothing
# else: a private session is not restored.
scenario_5c() {
    echo "== scenario 5c: Firefox stays one maximized window (Ctrl+Q, File > Quit & Restart)"
    start_single_window
    # The one new tab closing every tab leaves (5b's last check): Ctrl+W on the
    # only tab leaves the window open with a new tab (closeWindowWithLastTab).
    setup_step ctrl-w-last-tab "Ctrl+W on the only tab, to leave a new tab" \
        close_tabs untitled || return 0
    check_not_restarted ctrl-q-cancel untitled in_x xdotool key ctrl+q sleep 1.5 key Escape
    check_restarted ctrl-q private main in_x xdotool key ctrl+q sleep 1.5 key Return
    check_restarted file-quit-restart private main \
        in_x xdotool key alt+f sleep 1 key q sleep 1.5 key Return
}
scenario_5d() {
    echo "== scenario 5d: Firefox stays one maximized window (main menu's Quit & Restart, shutdown key)"
    start_single_window
    check_restarted appmenu-quit-restart private main appmenu_last_item sleep 1.5 key Return
    check_restarted shutdown-key private main in_x xdotool key ctrl+alt+shift+q
}

# Serves the files in DIR on 127.0.0.1:WEB_PORT in the test container's network
# namespace (torrent_server.py; the container still has no network), and waits
# until it answers.
WEB_PORT=8765 # download-page.html links to this port
start_web_server() {
    local deadline=$((SECONDS + 30))
    docker rm -f -v "$CONTAINER-web" >/dev/null 2>&1 || true
    docker run -d --rm --name "$CONTAINER-web" --network "container:$CONTAINER" \
        -v "$E2E_DIR:/e2e:ro" -v "$1:/srv:ro" "$PROBE_IMAGE" \
        python -I /e2e/torrent_server.py "$WEB_PORT" /srv >/dev/null
    until docker exec "$CONTAINER" wget -q -O /dev/null "http://127.0.0.1:$WEB_PORT/" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            docker logs "$CONTAINER-web" 2>&1 | sed 's/^/      /'
            end_run web-server-start "torrent_server.py did not answer within 30 s (its log above)"
        fi
        sleep 0.5
    done
}

# Stops the test container as `docker stop` stops the service: the image's
# shutdown script quits Firefox with its shutdown key (config/firefox-services/kill),
# so it saves the profile. Waits until Docker has removed it (--rm), so its
# name is free again.
stop_firefox() {
    local deadline=$((SECONDS + 60))
    docker rm -f -v "$CONTAINER-web" "$PROBE_CONTAINER" >/dev/null 2>&1 || true
    docker stop "$CONTAINER" >/dev/null
    while docker inspect "$CONTAINER" >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            end_run container-removed "$CONTAINER was not removed within 60 s after it stopped"
        fi
        sleep 0.5
    done
}

# check_clean_stop LABEL: stop_firefox, then checks the container's log of the
# shutdown: Firefox quit by itself (status 0) within the 5 s the image's
# shutdown script waits after pressing its key, so the key reached it and no
# dialog held it up, and the image did not start Firefox again
# (KEEP_APP_RUNNING=1 restarts it only while the container runs).
check_clean_stop() {
    local log=$WORK/stop.log follower result
    docker logs -f -t "$CONTAINER" >"$log" 2>&1 &
    follower=$!
    stop_firefox
    wait "$follower" || true
    checks=$((checks + 1))
    result=$(python3 -I -c '
import re, sys
from datetime import datetime
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
def when(line):
    stamp = re.match(r"(\S+?)(\.\d+)?Z ", line)
    fraction = (stamp.group(2) or ".0")[:7]
    return datetime.fromisoformat(stamp.group(1) + fraction + "+00:00")
start = next((i for i, l in enumerate(lines) if "SIGTERM received" in l), None)
if start is None:
    sys.exit("no shutdown in the log")
after = lines[start:]
stopping = next((l for l in after if "stopping service '"'"'app'"'"'" in l), None)
exited = next((l for l in after if "service '"'"'app'"'"' exited" in l), None)
if not stopping or not exited:
    sys.exit("the log does not show Firefox stopping")
if any("starting service '"'"'app'"'"'" in l for l in after):
    sys.exit("Firefox was started again during the shutdown")
seconds = (when(exited) - when(stopping)).total_seconds()
status = exited.split("] ", 1)[1]
if "(with status 0)" not in exited or seconds >= 5:
    sys.exit(f"{status} after {seconds:.1f} s")
print(f"{status} after {seconds:.1f} s")
' "$log" 2>&1) && {
        printf 'ok    %-22s %s\n' "$1" "$result"
        return 0
    }
    printf 'FAIL  %-22s %s\n' "$1" "$result"
    failures=$((failures + 1))
}

# Loads URL in the shown tab of WINDOW, typed into the address bar as a person
# would (type_url), and waits up to 15 s for a title that starts with PREFIX;
# prints that title.
load_url() {
    type_url "$1" windowactivate --sync "$WINDOW" || return 1
    wait_title "$2"
}

# setup_load LABEL WIN URL PREFIX: load_url in window WIN, for a page the checks
# after it need. Returns 0 if the page shows. If not, those checks could only
# fail, each after its timeouts (a page left unloaded once turned into eight
# failures, then a right-click and P meant for a link on it opened Save Page
# As): fails as check LABEL, with what the container shows, and returns 1 for
# the scenario to stop: `setup_load ... || return 0` (0: under set -e, a
# scenario that fails would stop the run before its summary).
setup_load() {
    local label=$1 win=$2
    shift 2
    in_window "$win" load_url "$@" >/dev/null && return 0
    checks=$((checks + 1))
    printf "FAIL  %-22s %s did not show (the window shows '%s'); the checks after it need it, so the scenario stops\n" \
        "$label" "$1" "$(in_window "$win" shown_title || true)"
    failure_details "$label"
    failures=$((failures + 1))
    return 1
}

# setup_step LABEL WHAT COMMAND...: setup_load for any other step the checks
# after it need (a click, a key, a window opened), which COMMAND does and
# waits for: returns 0 if COMMAND succeeds, else fails as check LABEL, saying
# WHAT did not happen, and returns 1 for the scenario to stop.
setup_step() {
    local label=$1 what=$2
    shift 2
    "$@" >/dev/null && return 0
    checks=$((checks + 1))
    printf "FAIL  %-22s %s did not happen (the window shows '%s'); the checks after it need it, so the scenario stops\n" \
        "$label" "$what" "$(shown_title || true)"
    failure_details "$label"
    failures=$((failures + 1))
    return 1
}

# tab_shows WIN NAME COMMAND...: runs COMMAND, then waits until window WIN
# shows page NAME (see tab_prefix).
tab_shows() {
    local win=$1 name=$2
    shift 2
    "$@" || return 1
    wait_title_in "$win" "$(tab_prefix "$name")"
}

# new_private_window NAME COMMAND...: runs COMMAND, which opens the first
# private window, then finds it (PWINDOW) and waits until it shows page NAME.
new_private_window() {
    local name=$1
    shift
    "$@" || return 1
    find_private_window || return 1
    wait_title_in "$PWINDOW" "$(tab_prefix "$name")"
}

# click_band NAME: in window WINDOW, shown first, clicks the band of
# single-window-page.html that opens page NAME as checks in scenarios 5 and 10
# do (a Shift+click for shift-click), so a shard can make the tabs earlier
# checks made.
click_band() {
    local y
    case $1 in
        popup) y=$popup_y ;;
        popup-plain) y=$popup_plain_y ;;
        blank) y=$blank_y ;;
        shift-click)
            in_x xdotool windowactivate --sync "$WINDOW" \
                mousemove "$((DISPLAY_W / 2))" "$link_y" keydown shift click 1 keyup shift
            return
            ;;
        *) return 1 ;;
    esac
    in_x xdotool windowactivate --sync "$WINDOW" mousemove "$((DISPLAY_W / 2))" "$y" click 1
}

# setup_bands LABEL NAME...: clicks the band for each NAME in turn (click_band)
# and waits until WINDOW shows it, each a setup_step; returns 1 if one fails.
setup_bands() {
    local label=$1 name
    shift
    for name in "$@"; do
        setup_step "$label-$name" "the $name band's tab" tab_shows "$WINDOW" "$name" \
            click_band "$name" || return 1
    done
}

# Prints how many visits Firefox recorded to cookie-page.html in the history of
# the profile in DIR (a host directory mounted at /config), read from a copy of
# places.sqlite after the container stopped; 0 without one.
cookie_page_visits() {
    local places=$1/profile/places.sqlite copy=$WORK/places-copy
    rm -rf "$copy"
    mkdir "$copy"
    if [[ ! -f "$places" ]]; then
        echo 0
        return 0
    fi
    cp "$places" "$copy/"
    [[ ! -f "$places-wal" ]] || cp "$places-wal" "$copy/"
    python3 -I -c '
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
print(con.execute(
    "SELECT COALESCE(SUM(visit_count), 0) FROM moz_places WHERE url LIKE ?",
    ("%/cookie-page.html",),
).fetchone()[0])
' "$copy/places.sqlite"
}

# Succeeds if the cookies of the profile in DIR (a host directory mounted at
# /config) hold a cookie NAME, read from a copy of cookies.sqlite after the
# container stopped: profile_has_cookie DIR NAME.
profile_has_cookie() {
    local cookies=$1/profile/cookies.sqlite copy=$WORK/cookies-copy
    rm -rf "$copy"
    mkdir "$copy"
    [[ -f "$cookies" ]] || return 1
    cp "$cookies" "$copy/"
    [[ ! -f "$cookies-wal" ]] || cp "$cookies-wal" "$copy/"
    python3 -I -c '
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
count = con.execute("SELECT COUNT(*) FROM moz_cookies WHERE name = ?", (sys.argv[2],)).fetchone()[0]
sys.exit(0 if count else 1)
' "$copy/cookies.sqlite" "$2"
}

# check_kept LABEL EXPECTED ACTUAL: ok if ACTUAL is EXPECTED.
check_kept() {
    checks=$((checks + 1))
    if [[ "$3" == "$2" ]]; then
        printf 'ok    %-22s %s\n' "$1" "$3"
    else
        printf 'FAIL  %-22s %s (expected %s)\n' "$1" "${3:-(nothing)}" "$2"
        failures=$((failures + 1))
    fi
}

# check_restart MODE KEPT VISITS: on a fresh /config ($WORK/profile-MODE), loads
# cookie-page.html, which sets the cookie e2e-main, restarts the container on
# the same /config and loads it again. KEPT ("e2e-main" or "none") is the
# cookies the page must find then, and VISITS ("0" or "1 or more") what history
# must show after the
# first run. Further arguments go to start_firefox_windowed. Leaves the second
# container running, with the page's server.
check_restart() {
    local mode=$1 kept=$2 visits=$3 profile=$WORK/profile-$1 title count
    shift 3
    mkdir -p "$profile"
    chmod 0777 "$profile" # the image takes /config over for its user
    start_firefox_windowed blank-page.html "e2e blank page" -v "$profile:/config" "$@"
    start_web_server "$E2E_DIR"
    title=$(load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html" "e2e cookie page cookies") || true
    check_kept "$mode-first-visit" "e2e cookie page cookies=none" "$title"
    stop_firefox
    count=$(cookie_page_visits "$profile")
    if [[ "$visits" != 0 && "$count" =~ ^[1-9][0-9]*$ ]]; then
        count="1 or more"
    fi
    check_kept "$mode-history" "$visits" "$count"
    start_firefox_windowed blank-page.html "e2e blank page" -v "$profile:/config" "$@"
    start_web_server "$E2E_DIR"
    title=$(load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html" "e2e cookie page cookies") || true
    check_kept "$mode-cookie-restart" "e2e cookie page cookies=$kept" "$title"
}

scenario_6m() {
    echo "== scenario 6m: private browsing on: nothing is kept"
    # Private browsing keeps cookies and history only until Firefox quits.
    check_restart on none 0
    # Quit & Restart quits Firefox, so it ends the private session without a
    # container restart: the cookie the page just set is there until then.
    # Off the cookie page first, so the check below sees it load again.
    setup_load on-blank-page "$WINDOW" file:///e2e/blank-page.html "e2e blank page" || return 0
    title=$(load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html" "e2e cookie page cookies") || true
    check_kept on-cookie-in-session "e2e cookie page cookies=e2e-main" "$title"
    check_restarted on-quit-restart private e2e-blank in_x xdotool key ctrl+q sleep 1.5 key Return
    title=$(load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html" "e2e cookie page cookies") || true
    check_kept on-cookie-quit-restart "e2e cookie page cookies=none" "$title"
    check_clean_stop on-clean-stop
}
# The indicator, then the switch from on to off, on a /config of its own that
# had private browsing on at the start before the switch. The indicator is
# read first, so the absence check after the switch waits for as long as the
# icon took to show in this run allows (indicator_absent_wait), not 15 s.
scenario_6s() {
    echo "== scenario 6s: private browsing on: the indicator is shown; then off"
    local profile=$WORK/profile-on-to-off
    mkdir -p "$profile"
    chmod 0777 "$profile" # the image takes /config over for its user
    start_firefox_windowed blank-page.html "e2e blank page" -v "$profile:/config"
    checks=$((checks + 1))
    read_indicator
    if ((INDICATOR_PIXELS >= INDICATOR_MIN)); then
        printf 'ok    %-22s %s\n' private-indicator "$INDICATOR"
    else
        printf 'FAIL  %-22s mask icon not in the tab strip: %s\n' private-indicator "$INDICATOR"
        failures=$((failures + 1))
    fi
    stop_firefox
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    start_firefox_windowed blank-page.html "e2e blank page" -v "$profile:/config"
    check_prefs
    check_indicator on-to-off-indicator no
}

# Firefox saves a .torrent link straight into /config/downloads, which
# qBittorrent watches. The image's default prefs set browser.download.dir to
# /config/downloads. Firefox 151 asks before saving a .torrent from a file: URL
# (measured), so the file comes over HTTP, as application/x-bittorrent, from
# torrent_server.py in the container's network namespace (the container still
# has no network). make_test_torrent makes the file, $WORK/web/test.torrent,
# once, for scenarios 7 and 10, and sets TORRENT_SHA to its SHA-256.
TORRENT_SHA=""
make_test_torrent() {
    [[ -z "$TORRENT_SHA" ]] || return 0
    mkdir -p "$WORK/web"
    python3 -I "$REPO/tests/qbittorrent/make_torrent.py" "$WORK/torrent-content" \
        "$WORK/web/test.torrent" >/dev/null
    TORRENT_SHA=$(shasum -a 256 "$WORK/web/test.torrent" | cut -d ' ' -f 1)
}

# check_torrent_download LABEL DIR: with download-page.html shown, clicks its
# link to test.torrent (served from $WORK/web) and checks that the file lands
# in DIR (mounted at /config/downloads) without a prompt.
check_torrent_download() {
    local label=$1 dir=$2 deadline downloaded="" listing prompts="" window properties
    checks=$((checks + 1))
    in_x xdotool windowactivate --sync "$WINDOW" \
        mousemove "$((DISPLAY_W / 2))" "$((DISPLAY_H / 2))" click 1
    # Firefox writes NAME.part, then renames it. A save prompt would leave only the
    # .part file until someone answers it.
    deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        if [[ -f "$dir/test.torrent" ]] &&
            ! compgen -G "$dir/*.part" >/dev/null &&
            [[ "$(shasum -a 256 "$dir/test.torrent" | cut -d ' ' -f 1)" == "$TORRENT_SHA" ]]; then
            downloaded=yes
            break
        fi
        sleep 0.5
    done
    listing=$(find "$dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | paste -sd ' ' -)
    # Any visible window besides the browser windows, except Firefox's pop-up panels
    # (role "Popup", such as the first private download's "Files stay on your
    # device" notice), would be a prompt such as "Opening test.torrent".
    for window in $(in_x xdotool search --onlyvisible --name . 2>/dev/null || true); do
        [[ "$window" != "$WINDOW" && "$window" != "$PWINDOW" ]] || continue
        properties=$(in_x obxprop --id "$window")
        if ! grep -qxF 'WM_WINDOW_ROLE(STRING) = "Popup"' <<<"$properties"; then
            prompts+="\"$(in_x xdotool getwindowname "$window")\" "
        fi
    done
    if [[ -n "$downloaded" && -z "$prompts" ]]; then
        printf 'ok    %-22s /config/downloads: %s\n' "$label" "$listing"
    else
        printf 'FAIL  %-22s /config/downloads: %s; other windows: %s\n' "$label" \
            "${listing:-(empty)}" "${prompts:-none}"
        failures=$((failures + 1))
    fi
}

scenario_7() {
    echo "== scenario 7: a .torrent link downloads into /config/downloads without a prompt"
    checks=$((checks + 1))
    if ! python3 -I -c '
import json, sys
volumes = json.load(sys.stdin)["services"]["firefox"].get("volumes", [])
sys.exit(not any(v["target"] == "/config/downloads" and not v.get("read_only") for v in volumes))
' <"$WORK/compose.json"; then
        echo "FAIL  the firefox service mounts no writable directory at /config/downloads"
        failures=$((failures + 1))
    else
        echo "ok    the firefox service mounts a writable directory at /config/downloads"
    fi
    mkdir -p "$WORK/downloads"
    chmod 0777 "$WORK/downloads" # Firefox runs as the image's user
    start_firefox_windowed download-page.html "e2e download page" \
        -v "$WORK/downloads:/config/downloads"
    make_test_torrent
    start_web_server "$WORK/web"
    check_torrent_download torrent-download "$WORK/downloads"
}

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
scenario_8() {
    echo "== scenario 8: WebRTC offers no host candidates, even to a capturing page"
    STUN_MAPPED=203.0.113.7 # a documentation address (RFC 5737), on no interface
    OTHER_ADDRESS=10.99.0.2 # webrtc-page.html asks for the STUN server here
    DEFAULT_ADDRESS=10.98.0.2
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
            docker logs "$CONTAINER-stun" 2>&1 | sed 's/^/      /'
            end_run stun-server-start "stun_server.py did not listen within 30 s (its log above)"
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
    checks=$((checks + 1))
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
}

# With WEB_AUDIO=1 the image runs PulseAudio (a null sink, socket
# /tmp/pulseaudio.sock) for Firefox, records the sink's monitor (audiorecorder,
# socket /tmp/vnc-audio.sock: s16le, 2 channels, 44.1 kHz), and nginx relays
# that on /websockify-audio, port 5800, to the web UI's PCMPlayer. Each check
# below covers one hop, so a failure says where the sound stops. The probes run
# in the container's network namespace; the sockets are files in its /tmp, so
# the checks of those use docker exec.
TONE=tone:1000,1500 # audio-page.html's left and right frequencies

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
    probe ws_audio_probe.py ws 127.0.0.1 5800 "$1" "$2"
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
    clients=$(probe unix_peers_probe.py /tmp/pulseaudio.sock) || return 1
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

scenario_9() {
    echo "== scenario 9: a page's sound reaches the web UI's audio stream"
    audio_failures=$failures
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
}

# check_indicator LABEL SHOWN: the private browsing indicator is shown (SHOWN
# "yes") or not ("no") in the test container's tab strip.
check_indicator() {
    checks=$((checks + 1))
    if [[ "$2" == no ]]; then
        read_indicator "$(indicator_absent_wait)"
    else
        read_indicator
    fi
    if [[ "$2" == yes ]] && ((INDICATOR_PIXELS >= INDICATOR_MIN)); then
        printf 'ok    %-22s shown: %s\n' "$1" "$INDICATOR"
    elif [[ "$2" == no ]] && ((INDICATOR_PIXELS < INDICATOR_MIN)); then
        printf 'ok    %-22s not shown: %s\n' "$1" "$INDICATOR"
    else
        printf 'FAIL  %-22s want shown: %s, got %s\n' "$1" "$2" "$INDICATOR"
        failures=$((failures + 1))
    fi
}

# With private browsing off (FIREFOX_PRIVATE_BROWSING false or unset), Firefox
# keeps history, cookies and site data in /config, as a normal profile, and
# opens private windows on request, as Firefox itself does. Firefox moves no
# tab between a private and a normal window, so there can be one of each:
# every new window's tabs, and every pop-up, must land in the window of their
# kind, and both windows stay maximized. Then the switch from off to on, on a
# /config that had private browsing off (scenario 6 ends with the switch from
# on to off): the image writes the pref again at every start, so it applies at
# once.
# The shards after 10a each start a fresh container with private browsing
# off, and first make the tabs, windows and cookies their checks start from,
# with the same actions the checks before them use, each waited for
# (setup_load, setup_step): a step that fails stops the shard.

# The tabs scenario 10's normal window has after its pop-up checks, and its
# private window after its first private windows.
SC10_NORMAL_TABS="main popup popup-plain blank shift-click"
SC10_PRIVATE_TABS="private context-link other"

# The profile is kept across a restart.
scenario_10a() {
    echo "== scenario 10a: private browsing off: the profile is kept"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    check_restart off e2e-main "1 or more"
    check_prefs
    # Nothing is read after this: the EXIT trap removes the container.
}

# Private windows open as in Firefox itself, and really are private.
scenario_10b() {
    echo "== scenario 10b: private browsing off: private windows on request"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    start_firefox_windowed
    start_web_server "$E2E_DIR"
    # The normal window's cookie e2e-main, which off-normal-cookies must find
    # (10a checks that the profile keeps it): cookie-page.html sets it.
    setup_load off-main-cookie "$WINDOW" "http://127.0.0.1:$WEB_PORT/cookie-page.html" \
        "e2e cookie page cookies" || return 0
    setup_load off-main-page "$WINDOW" file:///e2e/single-window-page.html "sw:main " || return 0
    check_windows off-ctrl-shift-p main untitled private untitled in_x xdotool key ctrl+shift+p
    # Really private: each window has its own cookies. The normal window has
    # e2e-main from above; the page sets e2e-<fragment>.
    title=$(in_window "$PWINDOW" load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html#private" \
        "e2e cookie page cookies") || true
    check_kept off-private-cookies "e2e cookie page cookies=none" "$title"
    title=$(in_window "$WINDOW" load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html#main" \
        "e2e cookie page cookies") || true
    check_kept off-normal-cookies "e2e cookie page cookies=e2e-main" "$title"
    setup_load off-private-page "$PWINDOW" "file:///e2e/single-window-page.html#private" \
        "sw:private " || return 0
    setup_load off-main-page-again "$WINDOW" file:///e2e/single-window-page.html "sw:main " || return 0
    # File > New Private Window (Alt+F, then its access key W) from the normal window.
    check_windows off-file-menu main "private file-menu" private file-menu \
        open_then_load file-menu "$PWINDOW" key alt+f sleep 1 key w
    check_windows off-close-private-tab main private private private \
        in_window "$PWINDOW" in_x xdotool key ctrl+w
    # The link's context menu: "Open Link in New Private Window" (access key P).
    check_windows off-link-private main "private context-link" private context-link \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$context_link_y" click 3 sleep 1 key p
    check_windows off-other-private main "$SC10_PRIVATE_TABS" private other \
        open_private_window other
}

# Ctrl+N, pop-ups and new windows land in the window of their kind.
scenario_10c() {
    echo "== scenario 10c: private browsing off: pop-ups and new windows in the window of their kind"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    start_firefox_windowed single-window-page.html "sw:main "
    # The private window's tabs 10b's checks leave: its first page, a link
    # opened from the normal window's context menu, and another private window's.
    setup_step off-private-window "a private window showing private" \
        new_private_window private open_private_window private || return 0
    setup_step off-context-link "the context menu's link in the private window" \
        tab_shows "$PWINDOW" context-link in_window "$WINDOW" \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$context_link_y" click 3 sleep 1 key p || return 0
    setup_step off-other-private-window "another private window's page" \
        tab_shows "$PWINDOW" other open_private_window other || return 0
    setup_step off-normal-shown "the normal window shown" \
        in_x xdotool windowactivate --sync "$WINDOW" || return 0
    check_windows off-ctrl-n main "$SC10_PRIVATE_TABS" normal - in_x xdotool key ctrl+n
    # Pop-ups and new windows from a page in the normal window.
    private_tabs=$SC10_PRIVATE_TABS
    check_windows off-popup "main popup" "$private_tabs" normal popup \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_y" click 1
    check_windows off-popup-plain "main popup popup-plain" "$private_tabs" normal popup-plain \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_plain_y" click 1
    check_windows off-target-blank "main popup popup-plain blank" "$private_tabs" normal blank \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$blank_y" click 1
    normal_tabs=$SC10_NORMAL_TABS
    check_windows off-shift-click "$normal_tabs" "$private_tabs" normal shift-click \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$link_y" keydown shift click 1 keyup shift
    # The same from a page in the private window: the tabs are private.
    check_windows off-private-popup "$normal_tabs" "$private_tabs popup" private popup \
        in_window "$PWINDOW" in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_y" click 1
    check_windows off-private-popup-plain "$normal_tabs" "$private_tabs popup popup-plain" private \
        popup-plain in_window "$PWINDOW" \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$popup_plain_y" click 1
    check_windows off-private-blank "$normal_tabs" "$private_tabs popup popup-plain blank" private \
        blank in_window "$PWINDOW" in_x xdotool mousemove "$((DISPLAY_W / 2))" "$blank_y" click 1
    check_windows off-private-shift-click "$normal_tabs" \
        "$private_tabs popup popup-plain blank shift-click" private shift-click \
        in_window "$PWINDOW" \
        in_x xdotool mousemove "$((DISPLAY_W / 2))" "$link_y" keydown shift click 1 keyup shift
}

# Ctrl+` and the Window menu switch between the windows; Close Window closes
# the private one.
scenario_10d() {
    echo "== scenario 10d: private browsing off: switching between the windows, closing the private one"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    start_firefox_windowed single-window-page.html "sw:main "
    # A private window, and the normal window's tabs 10c's checks leave (the
    # checks below read no private tabs, and the closing ones only the normal
    # window's), with the normal window shown.
    setup_step off-private-window "a private window showing private" \
        new_private_window private open_private_window private || return 0
    setup_bands off-band popup popup-plain blank shift-click || return 0
    setup_step off-normal-shown "the normal window shown" \
        in_x xdotool windowactivate --sync "$WINDOW" || return 0
    normal_tabs=$SC10_NORMAL_TABS
    # Switching: WINDOW is shown. Ctrl+` shows the next window, the Window menu
    # (Alt+W) the one chosen by number.
    check_shown off-ctrl-grave-private "$PWINDOW" in_x xdotool key ctrl+grave
    check_shown off-ctrl-grave-normal "$WINDOW" in_x xdotool key ctrl+grave
    check_shown off-window-menu-2 "$PWINDOW" in_x xdotool key alt+w sleep 1 key 2
    check_shown off-window-menu-1 "$WINDOW" in_x xdotool key alt+w sleep 1 key 1
    check_window_menu off-window-menu-two 2
    # Closing: the private window closes; the normal one, with its tabs, stays.
    check_windows off-ctrl-shift-w-private "$normal_tabs" - normal - \
        close_window "$PWINDOW" key ctrl+shift+w
    PWINDOW=""
    check_windows off-reopen-private "$normal_tabs" untitled private untitled \
        in_x xdotool key ctrl+shift+p
    check_windows off-window-menu-close "$normal_tabs" - normal - \
        close_window "$PWINDOW" key alt+w sleep 1 key c
    PWINDOW=""
    check_windows off-reopen-private-2 "$normal_tabs" untitled private untitled \
        in_x xdotool key ctrl+shift+p
}

# Quit & Restart reopens the normal window's tabs and keeps the cookie.
scenario_10e() {
    echo "== scenario 10e: private browsing off: Quit & Restart"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    start_firefox_windowed
    # The cookie e2e-main, the normal window's tabs 10c's checks leave (their
    # pop-ups' tabs are the ones session restore must bring back:
    # docs/agents_output/debugging/session-restore-adopted-tab.md), and the new
    # private window 10d's checks leave, with the normal window shown.
    start_web_server "$E2E_DIR"
    setup_load off-main-cookie "$WINDOW" "http://127.0.0.1:$WEB_PORT/cookie-page.html" \
        "e2e cookie page cookies" || return 0
    setup_load off-main-page "$WINDOW" file:///e2e/single-window-page.html "sw:main " || return 0
    setup_bands off-band popup popup-plain blank shift-click || return 0
    setup_step off-private-window "a new private window (Ctrl+Shift+P)" \
        new_private_window untitled in_window "$WINDOW" in_x xdotool key ctrl+shift+p || return 0
    setup_step off-normal-shown "the normal window shown" \
        in_x xdotool windowactivate --sync "$WINDOW" || return 0
    normal_tabs=$SC10_NORMAL_TABS
    # Quit & Restart asks first, then reopens the normal window's tabs, followed by
    # FF_OPEN_URL's page (blank-page.html); a private window is not reopened. The
    # profile is kept: the cookie too.
    check_windows off-ctrl-q-cancel "$normal_tabs" untitled normal - \
        in_x xdotool key ctrl+q sleep 1.5 key Escape
    restored_tabs="$normal_tabs e2e-blank"
    check_restarted off-ctrl-q normal "$restored_tabs" in_x xdotool key ctrl+q sleep 1.5 key Return
    title=$(load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html" "e2e cookie page cookies") || true
    check_kept off-cookie-quit-restart "e2e cookie page cookies=e2e-main" "$title"
}

# Closing the last window restarts Firefox; a .torrent link still downloads;
# `docker stop` quits Firefox cleanly.
scenario_10f() {
    echo "== scenario 10f: private browsing off: closing the last window, the download, the clean stop"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    mkdir -p "$WORK/downloads-off"
    chmod 0777 "$WORK/downloads-off"
    start_firefox_windowed blank-page.html "e2e blank page" -v "$WORK/downloads-off:/config/downloads"
    # Tabs that must not come back when Firefox starts again after its last
    # window closed (before, the window had the tabs Quit & Restart reopened).
    setup_load off-main-page "$WINDOW" file:///e2e/single-window-page.html "sw:main " || return 0
    setup_bands off-band popup popup-plain || return 0
    # Closing the last window quits Firefox, and the image starts it again, with
    # only FF_OPEN_URL's page: Ctrl+Shift+W, Window > Close Window (access key C).
    check_restarted off-ctrl-shift-w-last normal e2e-blank in_x xdotool key ctrl+shift+w
    check_restarted off-window-menu-close-last normal e2e-blank in_x xdotool key alt+w sleep 1 key c
    # The last window is private (the normal one closed first): Firefox starts
    # again with a normal window, and the private session is over.
    check_windows off-private-before-last e2e-blank untitled private untitled \
        in_x xdotool key ctrl+shift+p
    checks=$((checks + 1))
    if close_window "$WINDOW" key ctrl+shift+w &&
        [[ "$(browser_windows || true)" == "$PWINDOW" ]]; then
        printf 'ok    %-22s only the private window is left\n' off-close-normal-first
    else
        printf 'FAIL  %-22s windows: %s (want only %s)\n' off-close-normal-first \
            "$(browser_windows || true)" "$PWINDOW"
        failure_details off-close-normal-first
        failures=$((failures + 1))
    fi
    check_restarted off-close-last-private normal e2e-blank close_window "$PWINDOW" key ctrl+shift+w
    setup_load off-download-page "$WINDOW" file:///e2e/download-page.html "e2e download page" ||
        return 0
    make_test_torrent
    start_web_server "$WORK/web"
    check_torrent_download off-torrent-download "$WORK/downloads-off"
    check_clean_stop off-clean-stop
}

# The switch from off to on: a /config of its own with the cookie e2e-main
# from a normal session (10a checks that a container restart keeps it), now
# private. A private session has its own cookie jar, so the kept cookie does
# not show. That is meaningful only if the profile holds the cookie, so the
# setup reads it from the stopped profile's cookies.sqlite first.
scenario_10g() {
    echo "== scenario 10g: private browsing off, then on"
    local profile=$WORK/profile-off-to-on
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    mkdir -p "$profile"
    chmod 0777 "$profile" # the image takes /config over for its user
    start_firefox_windowed blank-page.html "e2e blank page" -v "$profile:/config"
    start_web_server "$E2E_DIR"
    setup_load off-main-cookie "$WINDOW" "http://127.0.0.1:$WEB_PORT/cookie-page.html" \
        "e2e cookie page cookies" || return 0
    stop_firefox
    setup_step off-cookie-kept "the cookie e2e-main in the stopped profile's cookies.sqlite" \
        profile_has_cookie "$profile" e2e-main || return 0
    FIREFOX_ARGS=("${SERVICE_ARGS[@]}")
    start_firefox_windowed blank-page.html "e2e blank page" -v "$profile:/config"
    check_indicator off-to-on-indicator yes
    start_web_server "$E2E_DIR"
    title=$(load_url "http://127.0.0.1:$WEB_PORT/cookie-page.html" "e2e cookie page cookies") || true
    check_kept off-to-on-cookie "e2e cookie page cookies=none" "$title"
}

# No indicator with private browsing off. Alone in its container: before the
# icon has shown in this process, the absence read takes its full 15 s
# (indicator_absent_wait).
scenario_10h() {
    echo "== scenario 10h: private browsing off: no indicator"
    FIREFOX_ARGS=("${OFF_ARGS[@]}")
    start_firefox_windowed
    check_indicator no-private-indicator no
}

# The image writes an FF_PREF_* value into prefs.js as it is, and Firefox takes
# anything but true there for off without a word (measured: yes, True, 1 and
# "true"). config/firefox-init.d/54-firefox-private-browsing.sh must stop the
# container first, saying why, so a typo meant to turn private browsing on
# can't leave it off.
scenario_11() {
    echo "== scenario 11: a FIREFOX_PRIVATE_BROWSING other than true or false stops the container"
    BAD_MESSAGE="54-firefox-private-browsing.sh: FIREFOX_PRIVATE_BROWSING is 'yes', not true or false."
    checks=$((checks + 1))
    docker rm -f -v "$CONTAINER-bad" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER-bad" --network none "${BAD_ARGS[@]}" "$IMAGE" >/dev/null
    deadline=$((SECONDS + 60))
    while [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER-bad")" == true ]] &&
        ((SECONDS < deadline)); do
        sleep "$START_POLL_S"
    done
    bad_state=$(docker inspect -f 'running={{.State.Running}} exit={{.State.ExitCode}}' "$CONTAINER-bad")
    bad_log=$(docker logs "$CONTAINER-bad" 2>&1)
    if [[ "$bad_state" == "running=false exit="[1-9]* ]] && grep -qF "$BAD_MESSAGE" <<<"$bad_log" &&
        ! grep -qF '56-firefox-set-prefs-from-env.sh: executing' <<<"$bad_log"; then
        printf 'ok    %-22s %s: %s\n' bad-value-stops "$bad_state" "$(grep -F "$BAD_MESSAGE" <<<"$bad_log")"
    else
        printf 'FAIL  %-22s %s; the log ends:\n' bad-value-stops "$bad_state"
        tail -n 5 <<<"$bad_log"
        failures=$((failures + 1))
    fi
    docker rm -f -v "$CONTAINER-bad" >/dev/null
}

scenario_12() {
    echo "== scenario 12: with the service's Firefox policies, Firefox saves no telemetry"
    local policies name archived=() ok=1
    policies=$(python3 -I -c '
import json, sys
volumes = json.load(open(sys.argv[1]))["services"]["firefox"].get("volumes", [])
print(next(v["source"] for v in volumes if v.get("target") == "/etc/firefox/policies/policies.json"))' \
        "$WORK/compose.json")
    checks=$((checks + 1))
    docker rm -f -v "$CONTAINER-policies" "$CONTAINER-nopolicies" >/dev/null 2>&1 || true
    # Firefox starts its telemetry session toolkit.telemetry.initDelay seconds
    # after startup (60 by default); the test-only pref starts it after 1, so
    # the wait below takes seconds, not a minute. DisableTelemetry turns
    # archiving off when Firefox starts, before the session does, so with the
    # policies nothing is archived whatever the delay; without them a quit
    # still archives some.
    local init_delay=FF_PREF_E2E_TELEMETRY_INIT_DELAY=toolkit.telemetry.initDelay=1
    # Not --rm: their profiles are read once they have stopped.
    docker run -d --name "$CONTAINER-policies" --network none "${NO_DNS_ARGS[@]}" \
        "${SERVICE_ARGS[@]}" -e "$init_delay" \
        -v "$policies:/etc/firefox/policies/policies.json:ro" "$IMAGE" >/dev/null
    docker run -d --name "$CONTAINER-nopolicies" --network none "${NO_DNS_ARGS[@]}" \
        "${SERVICE_ARGS[@]}" -e "$init_delay" "$IMAGE" >/dev/null
    # Firefox writes session-state.json when its telemetry session starts.
    for name in policies nopolicies; do
        deadline=$((SECONDS + 90))
        until docker exec "$CONTAINER-$name" test -e /config/profile/datareporting/session-state.json \
            2>/dev/null || ((SECONDS >= deadline)); do
            sleep "$START_POLL_S"
        done
    done
    # A clean quit archives Firefox's telemetry pings in the profile, unless the
    # DisableTelemetry policy turned archiving off.
    docker stop "$CONTAINER-policies" "$CONTAINER-nopolicies" >/dev/null
    for name in policies nopolicies; do
        mkdir "$WORK/telemetry-$name"
        docker cp "$CONTAINER-$name:/config/profile/datareporting" "$WORK/telemetry-$name/" \
            >/dev/null 2>&1 || true
        archived+=("$(find "$WORK/telemetry-$name" -path '*/archived/*' -type f | wc -l | tr -d ' ')")
    done
    docker rm -f -v "$CONTAINER-policies" "$CONTAINER-nopolicies" >/dev/null
    # Without the policies, the same quit must archive some: else this check sees nothing.
    if ((archived[0] != 0 || archived[1] == 0)); then
        ok=0
    fi
    if ((ok)); then
        printf 'ok    %-22s %s\n' no-telemetry \
            "0 pings archived with the policies, ${archived[1]} without them"
    else
        printf 'FAIL  %-22s %s\n' no-telemetry \
            "${archived[0]} ping(s) archived with the policies, ${archived[1]} without them (expected 0, and some)"
        failures=$((failures + 1))
    fi
}

# Prints how long the absence waits were at the end, if this run measured any
# latency for them, then this run's result as its last line: "all N checks
# passed", or "F of N check(s) failed" and exits 1.
summary() {
    if [[ -f "$WORK/latency-tab" || -f "$WORK/latency-window" ]]; then
        echo "absence waits: a second tab $(absence_wait tab) s ($(latency_note tab))," \
            "an action's change $(absence_wait window) s ($(latency_note window))"
    fi
    if ((failures > 0)); then
        echo "$failures of $checks check(s) failed"
        exit 1
    fi
    echo "all $checks checks passed"
}

# Runs each of SCENARIO_GROUPS as a run of this script with that group's
# scenarios, all at the same time, each writing its output to a log in WORK.
# Says when each group ends, with the last line it printed; when all have
# ended, prints each group's output in turn and the checks of all groups:
# "all N checks passed", or "F of N check(s) failed" and exits 1, as it does if
# a group ended without its summary line (or with "all passed" and a non-zero
# exit status). The summary line is what tells: after an expansion error
# (such as a bad array index), bash 3.2 exits with its EXIT trap's status, 0.
run_groups() {
    local logs=$WORK/groups start=$SECONDS remaining i status line total=0 failed=0
    local passed_re='^all ([0-9]+) checks passed$' failed_re='^([0-9]+) of ([0-9]+) check\(s\) failed$'
    local group=() statuses=() ended_after=() incomplete=""
    mkdir "$logs"
    for i in "${!SCENARIO_GROUPS[@]}"; do
        read -r -a group <<<"${SCENARIO_GROUPS[$i]}"
        E2E_SETUP_DIR=$WORK "$BASH" "$SELF" "${group[@]}" >"$logs/$i.log" 2>&1 &
        GROUP_PIDS[i]=$!
    done
    echo "started ${#SCENARIO_GROUPS[@]} groups of scenarios: $(printf '(%s) ' "${SCENARIO_GROUPS[@]}")"
    # Polls with kill -0, as tests/run-all.sh does: macOS's bash 3.2 has no wait -n.
    remaining=${#SCENARIO_GROUPS[@]}
    while ((remaining > 0)); do
        for i in "${!GROUP_PIDS[@]}"; do
            kill -0 "${GROUP_PIDS[$i]}" 2>/dev/null && continue
            status=0
            wait "${GROUP_PIDS[$i]}" || status=$?
            unset 'GROUP_PIDS[i]'
            remaining=$((remaining - 1))
            statuses[i]=$status
            ended_after[i]=$((SECONDS - start))
            line=$(tail -n 1 "$logs/$i.log")
            printf 'group %d (scenarios %s) ended after %d s, exit %d: %s\n' "$((i + 1))" \
                "${SCENARIO_GROUPS[$i]}" "${ended_after[$i]}" "$status" "${line:-(no output)}"
        done
        ((remaining == 0)) || sleep 1
    done
    for i in "${!SCENARIO_GROUPS[@]}"; do
        echo
        echo "=== group $((i + 1)): scenarios ${SCENARIO_GROUPS[$i]} (${ended_after[$i]} s, exit ${statuses[$i]})"
        cat "$logs/$i.log"
    done
    echo
    for i in "${!SCENARIO_GROUPS[@]}"; do
        line=$(tail -n 1 "$logs/$i.log")
        if [[ "$line" =~ $passed_re ]] && ((statuses[i] == 0)); then
            total=$((total + BASH_REMATCH[1]))
        elif [[ "$line" =~ $failed_re ]]; then
            failed=$((failed + BASH_REMATCH[1]))
            total=$((total + BASH_REMATCH[2]))
        else
            printf 'FAIL  group %d (scenarios %s) ended with exit %d without its summary line\n' \
                "$((i + 1))" "${SCENARIO_GROUPS[$i]}" "${statuses[$i]}"
            incomplete+=" $((i + 1))"
        fi
    done
    echo "the groups ran for $((SECONDS - start)) s"
    if [[ -n "$incomplete" ]]; then
        echo "$failed of $total check(s) failed; group(s)$incomplete stopped before their summary line"
        exit 1
    fi
    if ((failed > 0)); then
        echo "$failed of $total check(s) failed"
        exit 1
    fi
    echo "all $total checks passed"
}

if [[ -z "$SELECTED" ]]; then
    run_groups
else
    for n in $SELECTED; do
        # Each scenario starts with private browsing on and no private window
        # known, whatever the one before it left (one that stops early leaves
        # them as they were).
        FIREFOX_ARGS=("${SERVICE_ARGS[@]}")
        PWINDOW=""
        "scenario_$n"
    done
    summary
fi
