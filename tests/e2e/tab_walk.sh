#!/bin/sh
# The tab walk of run.sh's check_tabs, run inside the test container as one
# `docker exec` (as the X user, with DISPLAY set), so that each key and each
# read of the window title is not a round trip through the Docker CLI.
#
# Usage: tab_walk.sh WINDOW ABSENCE_S NAME...
#   WINDOW     the X window whose title shows the page; the keys go to the
#              focused window, which run.sh has made WINDOW
#   ABSENCE_S  how long, in seconds, a window of one tab gets to show a second
#              tab after Ctrl+PageDown (run.sh's absence_wait tab)
#   NAME...    the tabs WINDOW must have, in order (see tab_prefix)
# EARLIER_TITLE_LIST (environment): titles an earlier Firefox showed, one per
# line, which no step takes (see run.sh, SEEN_TITLES). TAB_WALK_CLOCK
# (environment): a file read as /proc/uptime is, for its first field, the time
# in seconds with two decimals (default /proc/uptime; tests/test_tab_walk.py
# gives one its stub xdotool advances).
#
# Prints, one per line: "latency MS" for each step that switched tabs (from
# the key to the title, in ms, to 10 ms), "title TITLE" for each title a step
# took, and on a mismatch "fail MESSAGE" (what differs; empty if the last step
# fails, as before), then exits 1. Exits 0 if WINDOW has exactly the tabs.

window=$1
absence=$2
shift 2
n=$#
nl='
'
earlier=""
[ -z "${EARLIER_TITLE_LIST:-}" ] || earlier="$nl$EARLIER_TITLE_LIST$nl"

# The time in centiseconds, from /proc/uptime (read by the shell: no process).
clock=${TAB_WALK_CLOCK:-/proc/uptime}
now_cs() {
    read -r up _ <"$clock"
    echo "${up%.*}${up#*.}"
}

# The title of the page WINDOW shows (run.sh's shown_title).
shown_title() {
    name=$(xdotool getwindowname "$window") || return 1
    name=${name% — Mozilla Firefox Private Browsing}
    name=${name% — Mozilla Firefox}
    case $name in
        "Mozilla Firefox" | "Mozilla Firefox Private Browsing") name="" ;;
    esac
    printf '%s\n' "$name"
}

# The title prefix of page NAME (run.sh's tab_prefix).
tab_prefix() {
    case $1 in
        untitled) echo "" ;;
        e2e-blank) echo "e2e blank page" ;;
        *) echo "sw:$1 " ;;
    esac
}

# wait_title PREFIX: waits up to 15 s until WINDOW's title starts with PREFIX
# (is "" when PREFIX is "") and is not in EARLIER_TITLE_LIST; sets title to it.
wait_title() {
    deadline=$(($(now_cs) + 1500))
    while :; do
        if title=$(shown_title); then
            case $earlier in
                *"$nl$title$nl"*) ;;
                *)
                    if [ -z "$1" ] && [ -z "$title" ]; then
                        echo "title $title"
                        return 0
                    fi
                    case $title in
                        "$1"*)
                            if [ -n "$1" ]; then
                                echo "title $title"
                                return 0
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
        [ "$(now_cs)" -lt "$deadline" ] || return 1
        sleep 0.05
    done
}

# switch_tab KEY PREFIX: presses KEY, which shows another tab, and waits until
# its title starts with PREFIX (wait_title); prints the latency.
switch_tab() {
    started=$(now_cs)
    xdotool key "$1" || return 1
    wait_title "$2" || return 1
    echo "latency $((($(now_cs) - started) * 10))"
}

fail() {
    echo "fail $1"
    exit 1
}

if [ "$n" -eq 1 ]; then
    if ! wait_title "$(tab_prefix "$1")"; then
        fail "the window shows '$(shown_title)', not $1"
    fi
    first=$title
    xdotool key ctrl+Next sleep "$absence" || fail ""
    if [ "$(shown_title)" != "$first" ]; then
        fail "a second tab exists: '$(shown_title)'"
    fi
    exit 0
fi
# Start from the last tab, so Alt+1 must change the page shown.
for last in "$@"; do :; done
if ! switch_tab alt+9 "$(tab_prefix "$last")"; then
    fail "the last tab is '$(shown_title)', not $last"
fi
k=0
for name in "$@"; do
    k=$((k + 1))
    if ! switch_tab "alt+$k" "$(tab_prefix "$name")"; then
        fail "tab $k is '$(shown_title)', not $name"
    fi
    [ "$k" -ne 1 ] || first=$title
done
last_title=$title
# Tab N must be the last tab: the next one is the first again.
if ! switch_tab ctrl+Next "$first"; then
    fail "after tab $n comes '$(shown_title)', not tab 1"
fi
switch_tab "alt+$n" "$last_title" || fail ""
