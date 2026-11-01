#!/usr/bin/env bash
# Runs the routine test suites at the same time and reports each one: the unit
# tests (python3 -m unittest discover -s tests), tests/e2e/run.sh,
# tests/browser/run.sh and tests/stack/run.sh (which checks the running stack:
# docker compose up -d first). The disruptive tests (tests/stack/recovery.sh,
# tests/stack/daemon-restart.sh) are not run.
#
# The suites share nothing: each names its containers after its own process
# id, the e2e and browser containers have no network, and the browser suite
# picks a free port. Each suite's output goes to SUITE.log in LOG_DIR (a new
# temporary directory unless set); when a suite ends, its result and time are
# printed, with its failure lines if it failed.
#
# Usage: tests/run-all.sh [SUITE...]   (unit, e2e, browser, stack; default: all)
# Exit status: 0 if every suite passed, 1 if any failed, 2 for a usage error.

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TESTS_DIR/.." && pwd)
ALL_SUITES=(unit e2e browser stack)

suites=("$@")
if ((${#suites[@]} == 0)); then
    suites=("${ALL_SUITES[@]}")
fi
for suite in "${suites[@]}"; do
    if [[ " ${ALL_SUITES[*]} " != *" $suite "* ]]; then
        echo "unknown suite: $suite (one of: ${ALL_SUITES[*]})" >&2
        exit 2
    fi
done

LOG_DIR=${LOG_DIR:-$(mktemp -d)}
mkdir -p "$LOG_DIR"
echo "logs: $LOG_DIR"

run_suite() {
    if [[ "$1" == unit ]]; then
        cd "$REPO" && python3 -m unittest discover -s tests
    else
        bash "$TESTS_DIR/$1/run.sh"
    fi
}

# Indexed arrays, one entry per suite (macOS's bash 3.2 has no associative ones).
pids=()
for suite in "${suites[@]}"; do
    run_suite "$suite" >"$LOG_DIR/$suite.log" 2>&1 &
    pids+=("$!")
done

start=$SECONDS
failed=0
remaining=${#suites[@]}
done_flags=()
while ((remaining > 0)); do
    for i in "${!suites[@]}"; do
        [[ -z "${done_flags[$i]:-}" ]] || continue
        kill -0 "${pids[$i]}" 2>/dev/null && continue
        done_flags[i]=1
        remaining=$((remaining - 1))
        status=0
        wait "${pids[$i]}" || status=$?
        if ((status == 0)); then
            printf 'ok    %-8s %4d s\n' "${suites[$i]}" "$((SECONDS - start))"
        else
            printf 'FAIL  %-8s %4d s  exit %d, log: %s\n' "${suites[$i]}" "$((SECONDS - start))" \
                "$status" "$LOG_DIR/${suites[$i]}.log"
            grep -E '^(FAIL|ERROR)' "$LOG_DIR/${suites[$i]}.log" | sed 's/^/      /' || true
            failed=$((failed + 1))
        fi
    done
    ((remaining == 0)) || sleep 1
done

if ((failed > 0)); then
    echo "$failed of ${#suites[@]} suite(s) failed in $((SECONDS - start)) s"
    exit 1
fi
echo "all ${#suites[@]} suite(s) passed in $((SECONDS - start)) s"
