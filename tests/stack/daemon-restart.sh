#!/usr/bin/env bash
# VERY DISRUPTIVE: this RESTARTS THE DOCKER ENGINE, and with it EVERY container
# on this host, this stack's and every other project's. It refuses to run
# without --yes-restart-docker.
#
# Checks the restart policy (unless-stopped on every service) across a Docker
# engine restart, as after a reboot. Two scenarios:
#
#   running  the engine restarts under the healthy stack. Within MAX_WAIT
#            seconds, every service must come back by itself (running, started
#            after the restart) and be healthy, the VPN container must have a
#            new network namespace, and each service with network_mode
#            service:<vpn> must be in it (not stranded on the old one). Then all
#            must stay up, healthy and unrestarted for SETTLE seconds. Prints
#            whether Autoheal restarted any, then runs tests/stack/run.sh.
#   stopped  `docker compose stop`, then the engine restarts: no service may
#            start (none running, StartedAt unchanged, no start event) within
#            OBSERVE seconds of the engine answering again. Then
#            `docker compose up -d` must bring every service back as above, and
#            tests/stack/run.sh runs.
#
# Each scenario first checks the stack is healthy, and aborts otherwise. It
# lists every other container on the host before, and at the end reports each
# whose state differs from before (it starts or stops none of them). If it
# stopped the stack and exits before starting it again, it runs
# `docker compose up -d`.
#
# The engine restart: `orb restart docker` on OrbStack; on any other engine,
# set DOCKER_RESTART_CMD (for example "sudo systemctl restart docker").
#
# Usage: tests/stack/daemon-restart.sh --yes-restart-docker [MAX_WAIT [SCENARIO...]]
#   (MAX_WAIT default 300; scenarios default: running stopped; SETTLE and
#   OBSERVE default 60 seconds; needs docker and python3; runs on bash 3.2)

set -euo pipefail

if [[ "${1:-}" != --yes-restart-docker ]]; then
    echo "REFUSED: this restarts the Docker engine and EVERY container on this host." >&2
    echo "Usage: $0 --yes-restart-docker [MAX_WAIT [SCENARIO...]]  (scenarios: running stopped)" >&2
    exit 2
fi
shift
MAX_WAIT=${1:-300}
if [[ ! "$MAX_WAIT" =~ ^[0-9]+$ ]]; then
    echo "MAX_WAIT must be a number of seconds, not '$MAX_WAIT'" >&2
    exit 2
fi
SCENARIOS=(running stopped)
if (($# > 1)); then
    SCENARIOS=("${@:2}")
fi
for scenario in "${SCENARIOS[@]}"; do
    case "$scenario" in
        running | stopped) ;;
        *)
            echo "unknown scenario '$scenario' (running or stopped)" >&2
            exit 2
            ;;
    esac
done
SETTLE=${SETTLE:-60}
OBSERVE=${OBSERVE:-60}
# How long to wait at the end for other projects' containers to be back.
HOST_WAIT=60
STACK_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$STACK_DIR/../.." && pwd)
COMPOSE=(docker compose -f "$REPO/docker-compose.yml")
WORK=$(mktemp -d)

failures=0
stack_stopped=no
events_pid=""

cleanup() {
    stop_events
    if [[ "$stack_stopped" == yes ]]; then
        echo "restoring: docker compose up -d (this script stopped the stack)"
        "${COMPOSE[@]}" up -d || echo "FAIL  could not start the stack again: run docker compose up -d"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    failures=$((failures + 1))
    printf 'FAIL  %s\n' "$*"
}
abort() {
    printf 'ABORT %s (before disrupting anything in this scenario)\n' "$*"
    exit 1
}

if [[ -n "${DOCKER_RESTART_CMD:-}" ]]; then
    RESTART_CMD=(bash -c "$DOCKER_RESTART_CMD")
    RESTART_DESC=$DOCKER_RESTART_CMD
elif [[ "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" == OrbStack ]] &&
    command -v orb >/dev/null 2>&1; then
    # OrbStack's engine is its built-in "docker" machine (orbctl info docker).
    RESTART_CMD=(orb restart docker)
    RESTART_DESC="orb restart docker"
else
    echo "no known way to restart this Docker engine: set DOCKER_RESTART_CMD" >&2
    exit 2
fi

"${COMPOSE[@]}" config --format json >"$WORK/config.json"
# One line per service: <container> <index of the service whose network it
# shares, or -> <has a health check: yes/no> <service>. A service without
# container_name gets Compose's default name, <project>-<service>-1.
python3 -I - "$WORK/config.json" >"$WORK/services" <<'EOF'
import json, sys
config = json.load(open(sys.argv[1]))
services = config["services"]
names = sorted(services)
def container(name):
    return services[name].get("container_name") or f"{config['name']}-{name}-1"
for name in names:
    service = services[name]
    mode = service.get("network_mode") or ""
    parent = names.index(mode[len("service:"):]) if mode.startswith("service:") else "-"
    test = (service.get("healthcheck") or {}).get("test")
    has_check = "yes" if test and test != ["NONE"] and not service["healthcheck"].get("disable") else "no"
    print(container(name), parent, has_check, name)
EOF
PROJECT=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$WORK/config.json")
CONTAINERS=()
PARENT=()
HAS_CHECK=()
AUTOHEAL=""
while read -r container parent has_check service; do
    CONTAINERS+=("$container")
    PARENT+=("$parent")
    HAS_CHECK+=("$has_check")
    if [[ "$service" == autoheal ]]; then
        AUTOHEAL=$container
    fi
done <"$WORK/services"
((${#CONTAINERS[@]} > 0)) || abort "docker-compose.yml has no services"
# Which containers' network namespace is checked: those that share another's,
# and the ones they share.
IN_NETNS=()
for i in "${!CONTAINERS[@]}"; do
    IN_NETNS[i]=no
done
for i in "${!CONTAINERS[@]}"; do
    if [[ "${PARENT[i]}" != - ]]; then
        IN_NETNS[i]=yes
        IN_NETNS[PARENT[i]]=yes
    fi
done

state() {
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | tr -d '[:space:]') || status=""
    echo "${status:-missing}"
}
health() {
    local status
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" \
        2>/dev/null | tr -d '[:space:]') || status=""
    echo "${status:-missing}"
}
describe() {
    docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} restart-policy={{.HostConfig.RestartPolicy.Name}} error={{if .State.Error}}{{.State.Error}}{{else}}none{{end}}' \
        "$1" 2>/dev/null || echo "missing"
}
# The container's StartedAt as integer nanoseconds since the epoch, or nothing.
# (RFC 3339 strings do not compare correctly: Go trims trailing zeros from the
# fraction.)
started_ns() {
    docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null | python3 -I -c '
import datetime, re, sys
line = sys.stdin.read().strip()
match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", line)
if match:
    base, fraction, zone = match.groups()
    zone = "+00:00" if zone == "Z" else zone
    seconds = int(datetime.datetime.fromisoformat(base + zone).timestamp())
    print(seconds * 10**9 + int((fraction or "").ljust(9, "0")))' || true
}
# The network namespace of the container's PID 1 (net:[<inode>]), or nothing.
netns() {
    local ns
    ns=$(docker exec "$1" readlink /proc/1/ns/net 2>/dev/null | tr -d '[:space:]') || ns=""
    if [[ "$ns" =~ ^net:\[[0-9]+\]$ ]]; then
        echo "$ns"
    fi
}

# Every container on the host that is not this stack's: name, state, restart
# policy (one per line).
host_inventory() {
    local ids=() id
    while IFS= read -r id; do
        ids+=("$id")
    done < <(docker ps -aq)
    ((${#ids[@]} > 0)) || return 0
    docker inspect -f '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}} {{with index .Config.Labels "com.docker.compose.project"}}{{.}}{{else}}-{{end}}' "${ids[@]}" |
        awk -v project="$PROJECT" '$4 != project { sub(/^\//, "", $1); print $1, $2, $3 }' | sort
}

# Checks the stack is healthy (every service running, healthy if it has a
# health check, each sharing container in its parent's namespace), and records
# each container's StartedAt and network namespace: precheck SCENARIO
precheck() {
    local i c
    echo "== $1: before"
    for i in "${!CONTAINERS[@]}"; do
        c=${CONTAINERS[i]}
        [[ "$(state "$c")" == running ]] || abort "$c is $(state "$c"), not running"
        if [[ "${HAS_CHECK[i]}" == yes && "$(health "$c")" != healthy ]]; then
            abort "$c is $(health "$c"), not healthy"
        fi
        BEFORE_STARTED[i]=$(started_ns "$c")
        [[ -n "${BEFORE_STARTED[i]}" ]] || abort "could not read $c's StartedAt"
        BEFORE_NS[i]=-
        if [[ "${IN_NETNS[i]}" == yes ]]; then
            BEFORE_NS[i]=$(netns "$c")
            [[ -n "${BEFORE_NS[i]}" ]] || abort "could not read $c's network namespace"
        fi
    done
    for i in "${!CONTAINERS[@]}"; do
        if [[ "${PARENT[i]}" != - && "${BEFORE_NS[i]}" != "${BEFORE_NS[PARENT[i]]}" ]]; then
            abort "${CONTAINERS[i]} is not in ${CONTAINERS[PARENT[i]]}'s network namespace"
        fi
        printf '%s: running, %s, restart policy %s%s\n' "${CONTAINERS[i]}" "$(health "${CONTAINERS[i]}")" \
            "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${CONTAINERS[i]}")" \
            "$([[ "${BEFORE_NS[i]}" != - ]] && echo ", network namespace ${BEFORE_NS[i]}")"
    done
}

# Restarts the engine and waits until it answers; sets t_restart (SECONDS) and
# restart_time (RFC 3339, UTC). Then records the stack's start and die events
# in $WORK/events (<name> <action>) until stop_events: the engine keeps only
# its last 256 events, and health checks' exec events push the starts out
# within a minute, so they are read from the moment it answers.
# restart_engine SCENARIO
restart_engine() {
    echo "== $1: restarting the Docker engine ($RESTART_DESC) at $(date +%T)"
    restart_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    t_restart=$SECONDS
    "${RESTART_CMD[@]}" || fail "$RESTART_DESC exited with status $?"
    until docker info >/dev/null 2>&1; do
        if ((SECONDS - t_restart >= MAX_WAIT)); then
            fail "the Docker engine did not answer within ${MAX_WAIT}s"
            echo "$failures failure(s)"
            exit 1
        fi
        sleep 1
    done
    docker events --since "$restart_time" --filter type=container \
        --filter "label=com.docker.compose.project=$PROJECT" --filter event=start --filter event=die \
        --format '{{.Actor.Attributes.name}} {{.Action}}' >"$WORK/events" 2>&1 &
    events_pid=$!
    echo "the engine answers $((SECONDS - t_restart))s after the restart began"
}
stop_events() {
    if [[ -n "$events_pid" ]]; then
        kill "$events_pid" 2>/dev/null || true
        wait "$events_pid" 2>/dev/null || true
        events_pid=""
    fi
}

# Milestones are <kind>:<container index>. Each requires the container to be
# back (running, and started after the recorded StartedAt), so none passes on
# the state before the restart took effect:
#   back     back
#   healthy  back and healthy (running, for a service without a health check)
#   netns    the VPN container: back, in a namespace other than the recorded
#            one; a container sharing its network: it and the VPN container
#            back, and in the VPN container's namespace, which is a new one
is_back() {
    local started
    [[ "$(state "${CONTAINERS[$1]}")" == running ]] || return 1
    started=$(started_ns "${CONTAINERS[$1]}")
    [[ -n "$started" ]] && ((started > BEFORE_STARTED[$1]))
}
check() {
    local kind=${1%%:*} i=${1#*:} c ns parent_ns
    c=${CONTAINERS[i]}
    is_back "$i" || return 1
    case "$kind" in
        back) ;;
        healthy)
            if [[ "${HAS_CHECK[i]}" == yes ]]; then
                [[ "$(health "$c")" == healthy ]]
            else
                [[ "$(state "$c")" == running ]]
            fi
            ;;
        netns)
            ns=$(netns "$c")
            [[ -n "$ns" ]] || return 1
            if [[ "${PARENT[i]}" == - ]]; then
                [[ "$ns" != "${BEFORE_NS[i]}" ]]
            else
                is_back "${PARENT[i]}" || return 1
                parent_ns=$(netns "${CONTAINERS[PARENT[i]]}")
                [[ "$ns" == "$parent_ns" && "$parent_ns" != "${BEFORE_NS[PARENT[i]]}" ]]
            fi
            ;;
    esac
}
label() {
    local kind=${1%%:*} i=${1#*:}
    case "$kind" in
        back) echo "${CONTAINERS[i]} is back (running, started again)" ;;
        healthy) echo "${CONTAINERS[i]} is healthy" ;;
        netns)
            if [[ "${PARENT[i]}" == - ]]; then
                echo "${CONTAINERS[i]} has a new network namespace"
            else
                echo "${CONTAINERS[i]} is in ${CONTAINERS[PARENT[i]]}'s new network namespace"
            fi
            ;;
    esac
}
# Prints the milestones for every container: back, healthy, and netns for
# those in IN_NETNS.
all_milestones() {
    local i
    for i in "${!CONTAINERS[@]}"; do
        echo "back:$i"
        echo "healthy:$i"
        if [[ "${IN_NETNS[i]}" == yes ]]; then
            echo "netns:$i"
        fi
    done
}

# Checks the milestones every 2 s until all pass or MAX_WAIT (counted from
# t_start) runs out, printing the seconds each took; fails the ones that did
# not pass, describing every container, and sets "slowest":
# run_milestones MILESTONE...
run_milestones() {
    local milestones=("$@") recovered=() i done_count=0 missing=() c
    for i in "${!milestones[@]}"; do
        recovered[i]=""
    done
    while ((SECONDS - t_start < MAX_WAIT)) && ((done_count < ${#milestones[@]})); do
        for i in "${!milestones[@]}"; do
            if [[ -z "${recovered[i]}" ]] && check "${milestones[i]}"; then
                recovered[i]=$((SECONDS - t_start))
                done_count=$((done_count + 1))
                printf 'ok    %4ds  %s\n' "${recovered[i]}" "$(label "${milestones[i]}")"
            fi
        done
        if ((done_count < ${#milestones[@]})); then
            sleep 2
        fi
    done
    slowest=0
    for i in "${!milestones[@]}"; do
        if [[ -z "${recovered[i]}" ]]; then
            missing+=("${milestones[i]}")
        elif ((recovered[i] > slowest)); then
            slowest=${recovered[i]}
        fi
    done
    if ((${#missing[@]} > 0)); then
        for i in "${missing[@]}"; do
            fail "not within ${MAX_WAIT}s: $(label "$i")"
        done
        for i in "${!CONTAINERS[@]}"; do
            c=${CONTAINERS[i]}
            echo "      $c: $(describe "$c")$([[ "${IN_NETNS[i]}" == yes ]] && echo " netns=$(netns "$c")")"
        done
        return 1
    fi
}

# All must stay running, healthy and unrestarted for SETTLE seconds, with each
# sharing container still in its parent's namespace at the end.
settle() {
    local i c started=() seen=() now
    for i in "${!CONTAINERS[@]}"; do
        started[i]=$(started_ns "${CONTAINERS[i]}")
        seen[i]=""
    done
    local end=$((SECONDS + SETTLE))
    while ((SECONDS < end)); do
        for i in "${!CONTAINERS[@]}"; do
            if [[ -z "${seen[i]}" ]] && ! check "healthy:$i"; then
                seen[i]="$(state "${CONTAINERS[i]}")/$(health "${CONTAINERS[i]}") $((SECONDS - t_start))s after the restart began"
            fi
        done
        sleep 2
    done
    local bad=0
    for i in "${!CONTAINERS[@]}"; do
        c=${CONTAINERS[i]}
        now=$(started_ns "$c")
        if [[ -n "${seen[i]}" ]]; then
            fail "$c was not healthy during the ${SETTLE}s settle period (${seen[i]})"
            bad=1
        fi
        if [[ "$now" != "${started[i]}" ]]; then
            fail "$c was started again during the ${SETTLE}s settle period"
            bad=1
        fi
        if [[ "${IN_NETNS[i]}" == yes ]] && ! check "netns:$i"; then
            fail "after the settle period: not true that $(label "netns:$i")"
            bad=1
        fi
    done
    if ((bad == 0)); then
        echo "ok    all stayed up, healthy and unrestarted for ${SETTLE}s"
    fi
}

# Stops recording events, and prints per container how often Docker started
# and stopped it since the restart, and what Autoheal restarted (its log):
# restart_report SCENARIO
restart_report() {
    local c starts dies healed
    stop_events
    for c in "${CONTAINERS[@]}"; do
        starts=$(awk -v name="$c" '$1 == name && $2 == "start"' "$WORK/events" | wc -l | tr -d ' ')
        dies=$(awk -v name="$c" '$1 == name && $2 == "die"' "$WORK/events" | wc -l | tr -d ' ')
        echo "$c: Docker events since the restart: $starts start(s), $dies die(s)"
    done
    if [[ -n "$AUTOHEAL" ]]; then
        healed=$(docker logs --since "$restart_time" "$AUTOHEAL" 2>&1 |
            sed -n 's/.*Container \/\([^ ]*\) (.*found to be unhealthy - Restarting.*/\1/p' |
            sort -u | paste -sd ' ' - || true)
        echo "$1: Autoheal restarted: ${healed:-none}"
    fi
}

run_stack_tests() {
    echo "== $1: tests/stack/run.sh"
    if "$STACK_DIR/run.sh"; then
        echo "ok    $1: tests/stack/run.sh passed"
    else
        fail "$1: tests/stack/run.sh failed"
    fi
}

# Scenario: the engine restarts under the running stack.
scenario_running() {
    local milestones=()
    precheck running
    restart_engine running
    t_start=$t_restart
    while IFS= read -r m; do milestones+=("$m"); done < <(all_milestones)
    if run_milestones "${milestones[@]}"; then
        echo "running: every service back and healthy $((slowest))s after the restart began"
        settle
        restart_report running
        run_stack_tests running
    else
        restart_report running
        echo "skipped tests/stack/run.sh: the stack did not recover"
    fi
}

# Scenario: the engine restarts under the stopped stack; nothing may start.
scenario_stopped() {
    local i c milestones=() now ran started_events
    precheck stopped
    echo "== stopped: docker compose stop"
    stack_stopped=yes
    "${COMPOSE[@]}" stop
    for i in "${!CONTAINERS[@]}"; do
        c=${CONTAINERS[i]}
        [[ "$(state "$c")" == exited ]] || fail "$c is $(state "$c") after docker compose stop"
        BEFORE_STARTED[i]=$(started_ns "$c")
    done
    restart_engine stopped
    local t_up=$SECONDS
    ran=()
    for i in "${!CONTAINERS[@]}"; do
        ran[i]=""
    done
    while ((SECONDS - t_up < OBSERVE)); do
        for i in "${!CONTAINERS[@]}"; do
            if [[ -z "${ran[i]}" && "$(state "${CONTAINERS[i]}")" == running ]]; then
                ran[i]="$((SECONDS - t_restart))s"
            fi
        done
        sleep 2
    done
    stop_events
    started_events=$(awk '$2 == "start" { print $1 }' "$WORK/events" | sort -u | paste -sd ' ' -)
    local started_any=no
    for i in "${!CONTAINERS[@]}"; do
        c=${CONTAINERS[i]}
        now=$(started_ns "$c")
        if [[ -n "${ran[i]}" ]]; then
            fail "$c was running ${ran[i]} after the restart began, though the stack was stopped"
            started_any=yes
        elif [[ "$now" != "${BEFORE_STARTED[i]}" ]]; then
            fail "$c was started after the engine restart (StartedAt changed), though the stack was stopped"
            started_any=yes
        fi
    done
    if [[ -n "$started_events" ]]; then
        fail "Docker recorded a start since the engine restart for: $started_events"
        started_any=yes
    fi
    if [[ "$started_any" == no ]]; then
        echo "ok    no service started within ${OBSERVE}s of the engine answering (state, StartedAt, events)"
    fi
    echo "== stopped: docker compose up -d"
    t_start=$SECONDS
    if "${COMPOSE[@]}" up -d; then
        stack_stopped=no
    else
        fail "docker compose up -d failed"
    fi
    while IFS= read -r m; do milestones+=("$m"); done < <(all_milestones)
    if run_milestones "${milestones[@]}"; then
        echo "stopped: every service back and healthy $((slowest))s after docker compose up -d"
        run_stack_tests stopped
    else
        echo "skipped tests/stack/run.sh: the stack did not recover"
    fi
}

# Reports each other container whose state differs from before, after waiting
# up to HOST_WAIT seconds for those that were running.
host_report() {
    local deadline=$((SECONDS + HOST_WAIT)) name was policy now_state pending changed=0
    while :; do
        host_inventory >"$WORK/host-after"
        pending=$(awk 'NR == FNR { now[$1] = $2; next } $2 == "running" && now[$1] != "running"' \
            "$WORK/host-after" "$WORK/host-before" | wc -l | tr -d ' ')
        ((pending == 0 || SECONDS >= deadline)) && break
        sleep 3
    done
    echo "== other containers on this host"
    while read -r name was policy; do
        now_state=$(awk -v name="$name" '$1 == name { print $2 }' "$WORK/host-after")
        now_state=${now_state:-missing}
        if [[ "$now_state" != "$was" ]]; then
            changed=$((changed + 1))
            echo "note  $name: was $was, now $now_state (restart policy $policy)"
        fi
    done <"$WORK/host-before"
    echo "$(wc -l <"$WORK/host-before" | tr -d ' ') other container(s); $changed in a different state than before"
}

host_inventory >"$WORK/host-before"
echo "== other containers on this host (name, state, restart policy)"
cat "$WORK/host-before"

for scenario in "${SCENARIOS[@]}"; do
    case "$scenario" in
        running) scenario_running ;;
        stopped) scenario_stopped ;;
    esac
done
host_report
if ((failures > 0)); then
    echo "$failures failure(s)"
    exit 1
fi
echo "all scenarios passed: ${SCENARIOS[*]}"
