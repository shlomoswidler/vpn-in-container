#!/usr/bin/env bash
# Measures how long the stack takes to recover from a VPN outage, and checks
# that nothing leaks around the VPN meanwhile. Two scenarios, both DISRUPTIVE:
#
#   tunnel-down  takes the tunnel interface down inside Gluetun (as when the VPN
#                connection drops). Gluetun's health check notices and reconnects
#                in the same container; nothing may be restarted.
#   restart      restarts the Gluetun container, which leaves Firefox, qBittorrent
#                and qSticky on its old, dead network until Autoheal restarts them
#                (Firefox's open tabs are lost). Autoheal must restart at least one.
#
# Each first checks that the stack is healthy and leaves through the VPN (and
# aborts otherwise), then records how many seconds pass until each part works
# again: Firefox's web UI, internet access from inside Firefox and qBittorrent
# through the VPN (not from the host's IP), qBittorrent's API, qBittorrent
# listening on Gluetun's forwarded port, and every service healthy. Throughout,
# it samples the public IP of Firefox's and qBittorrent's network every
# SAMPLE_INTERVAL seconds, and fails if any sample is the host's IP, or if
# anything is not back within MAX_WAIT seconds.
#
# Usage: tests/stack/recovery.sh [MAX_WAIT [SCENARIO...]]
#   (MAX_WAIT default 300; scenarios default: tunnel-down restart; needs docker,
#   curl and python3; runs on bash 3.2)

set -euo pipefail

MAX_WAIT=${1:-300}
SCENARIOS=(tunnel-down restart)
if (($# > 1)); then
    SCENARIOS=("${@:2}")
fi
for scenario in "${SCENARIOS[@]}"; do
    case "$scenario" in
        tunnel-down | restart) ;;
        *)
            echo "unknown scenario '$scenario' (tunnel-down or restart)" >&2
            exit 2
            ;;
    esac
done
SAMPLE_INTERVAL=2
STACK_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$STACK_DIR/../.." && pwd)
PLAIN_IMAGE=alpine:3.24
QBT_URL=http://localhost:9080
FIREFOX_URL=http://localhost:5800
WORK=$(mktemp -d)

failures=0
sampler_pid=""
events_pid=""

cleanup() {
    touch "$WORK/stop"
    if [[ -n "$events_pid" ]]; then
        kill "$events_pid" 2>/dev/null || true
    fi
    if [[ -n "$sampler_pid" ]]; then
        wait "$sampler_pid" 2>/dev/null || true
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

docker compose -f "$REPO/docker-compose.yml" config --format json >"$WORK/config.json"

# Prints a value from the resolved compose config: compose_value SERVICE KEY
# where KEY is "container" or "env:<NAME>".
compose_value() {
    python3 -I - "$WORK/config.json" "$1" "$2" <<'EOF'
import json, sys
config_path, service, key = sys.argv[1:]
svc = json.load(open(config_path))["services"][service]
if key == "container":
    print(svc["container_name"])
elif key.startswith("env:"):
    print(svc.get("environment", {}).get(key[4:], ""))
EOF
}

VPN=$(compose_value vpn container)
FIREFOX=$(compose_value firefox container)
QBT=$(compose_value qbittorrent container)
QSTICKY=$(compose_value qsticky container)
AUTOHEAL=$(compose_value autoheal container)
SHARING=("$FIREFOX" "$QBT" "$QSTICKY")
# qSticky's Gluetun API key, to read the forwarded port (never printed).
GLUETUN_API_KEY=$(compose_value qsticky env:GLUETUN_APIKEY)
export GLUETUN_API_KEY

# Prints each container's StartedAt as integer nanoseconds since the epoch.
# (RFC 3339 strings do not compare correctly: Go trims trailing zeros from the
# fraction.) started_ns CONTAINER...
started_ns() {
    docker inspect -f '{{.State.StartedAt}}' "$@" | python3 -I -c '
import datetime, re, sys
for line in sys.stdin.read().split():
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", line)
    if not match:
        sys.exit(f"unparsable StartedAt {line!r}")
    base, fraction, zone = match.groups()
    zone = "+00:00" if zone == "Z" else zone
    seconds = int(datetime.datetime.fromisoformat(base + zone).timestamp())
    print(seconds * 10**9 + int((fraction or "").ljust(9, "0")))'
}

# Prints the public IP a container's network leaves from, or nothing:
# egress_ip CONTAINER. curl where the image has it (qBittorrent), with
# ipinfo.io's address given (IPINFO_ADDR, from precheck), so the probe does
# not depend on DNS; otherwise BusyBox wget (Firefox). They share one network.
egress_ip() {
    local ip
    ip=$(docker exec -e IPINFO_ADDR="${IPINFO_ADDR:-}" "$1" sh -c 'if command -v curl >/dev/null 2>&1; then
            curl -s --max-time 5 ${IPINFO_ADDR:+--resolve "ipinfo.io:443:$IPINFO_ADDR"} https://ipinfo.io/ip
        else
            wget -qO- -T 5 https://ipinfo.io/ip
        fi' 2>/dev/null | tr -d '[:space:]') || true
    if [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
        echo "$ip"
    fi
}

health() {
    local status
    status=$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null | tr -d '[:space:]') || status=""
    echo "${status:-missing}"
}

forwarded_port() {
    docker exec -e GLUETUN_API_KEY "$QBT" sh -c \
        'curl -s --max-time 5 -H "X-API-Key: $GLUETUN_API_KEY" http://localhost:8000/v1/portforward' \
        2>/dev/null | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["port"])' 2>/dev/null || true
}
listen_port() {
    curl -s --max-time 3 "$QBT_URL/api/v2/app/preferences" |
        python3 -I -c 'import json, sys; print(json.load(sys.stdin)["listen_port"])' 2>/dev/null || true
}

# Checks the stack is healthy and leaves through the VPN, and reads the host's
# public IP; aborts the run otherwise: precheck SCENARIO
precheck() {
    local container ip
    echo "== $1: before"
    for container in "$VPN" "${SHARING[@]}"; do
        [[ "$(health "$container")" == healthy ]] || abort "$container is $(health "$container"), not healthy"
    done
    [[ "$(docker inspect -f '{{.State.Running}}' "$AUTOHEAL" 2>/dev/null)" == true ]] ||
        abort "$AUTOHEAL is not running"
    host_ip=""
    for _ in 1 2 3; do
        host_ip=$(docker run --rm "$PLAIN_IMAGE" wget -qO- -T 10 https://ipinfo.io/ip 2>/dev/null |
            tr -d '[:space:]') || true
        [[ "$host_ip" =~ ^[0-9.]+$ ]] && break
        host_ip=""
        sleep 3
    done
    [[ -n "$host_ip" ]] || abort "could not read the host's public IP"
    # The host's IPv6 egress, if it has one: a sample in its /64 is a leak too.
    host_ip6=$(curl -6 -s --max-time 10 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]') || host_ip6=""
    # ipinfo.io's address, so qBittorrent's probe does not depend on DNS (which
    # also fails while the tunnel is down, and would hide a leak).
    IPINFO_ADDR=$(docker exec "$QBT" getent ahostsv4 ipinfo.io 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
    [[ "$IPINFO_ADDR" =~ ^[0-9.]+$ ]] || abort "could not resolve ipinfo.io"
    for container in "$FIREFOX" "$QBT"; do
        ip=$(egress_ip "$container")
        [[ -n "$ip" && "$ip" != "$host_ip" ]] || abort "$container leaves from '$ip', not through the VPN"
        echo "$container leaves through the VPN ($ip); all containers healthy"
    done
}

# Samples both networks' public IP every SAMPLE_INTERVAL seconds (each sample
# in the background, so a slow one does not delay the next) until told to stop.
# Lines: <epoch seconds> <container> <IP, or - when there was none>
sample_round() {
    local container pids=()
    for container in "$FIREFOX" "$QBT"; do
        (
            at=$(date +%s)
            ip=$(egress_ip "$container")
            printf '%s %s %s\n' "$at" "$container" "${ip:--}" >>"$WORK/samples"
        ) &
        pids+=($!)
    done
    # Only these two: a bare wait would also wait for the docker events reader.
    wait "${pids[@]}"
}
sampler() {
    while [[ ! -e "$WORK/stop" ]]; do
        sample_round &
        sleep "$SAMPLE_INTERVAL"
    done
    wait
}
# Starts the sampler and Docker's record of what happens to the containers
# sharing the VPN's network (lifecycle events only; health checks also show up
# as exec events).
start_watch() {
    rm -f "$WORK/stop"
    : >"$WORK/samples"
    docker events --filter type=container --filter "container=$FIREFOX" --filter "container=$QBT" \
        --filter "container=$QSTICKY" --filter event=kill --filter event=stop --filter event=die \
        --filter event=start --filter event=restart \
        --format '{{.TimeNano}} {{.Actor.Attributes.name}} {{.Action}}' >"$WORK/events" 2>/dev/null &
    events_pid=$!
    sampler &
    sampler_pid=$!
}
# Stops both, after one more sample of each network.
stop_watch() {
    touch "$WORK/stop"
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=""
    sample_round
    sleep 1
    kill "$events_pid" 2>/dev/null || true
    wait "$events_pid" 2>/dev/null || true
    events_pid=""
}

check() {
    local ip forwarded container
    case "$1" in
        firefox-web-ui)
            [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$FIREFOX_URL/")" == 200 ]]
            ;;
        firefox-internet | qbittorrent-internet)
            container=$FIREFOX
            [[ "$1" == qbittorrent-internet ]] && container=$QBT
            ip=$(egress_ip "$container")
            [[ -n "$ip" && "$ip" != "$host_ip" ]]
            ;;
        qbittorrent-api)
            [[ "$(curl -s --max-time 3 "$QBT_URL/api/v2/app/version")" == v* ]]
            ;;
        qbittorrent-port)
            forwarded=$(forwarded_port)
            [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)) && [[ "$(listen_port)" == "$forwarded" ]]
            ;;
        vpn-reconnected)
            # Gluetun logged a new WireGuard connection since the tunnel went down.
            [[ "$(docker logs --since "$down_time" "$VPN" 2>&1)" == *"[wireguard] Connecting to "* ]]
            ;;
        tunnel-up)
            [[ "$(docker exec "$VPN" ip -o link show dev "$tun_if" 2>/dev/null)" == *",UP,"* ]]
            ;;
        vpn-healthy)
            [[ "$(health "$VPN")" == healthy ]]
            ;;
        all-rejoined)
            # Every container sharing the VPN's network was restarted after the VPN (so
            # it is on the new network) and is healthy, and the VPN is healthy. Health
            # alone means little here: right after the restart, all still report healthy.
            local started list count=0
            [[ "$(health "$VPN")" == healthy ]] || return 1
            list=$(started_ns "${SHARING[@]}") || return 1
            for started in $list; do
                ((started > vpn_started)) || return 1
                count=$((count + 1))
            done
            ((count == ${#SHARING[@]})) || return 1
            for container in "${SHARING[@]}"; do
                [[ "$(health "$container")" == healthy ]] || return 1
            done
            ;;
    esac
}

# Checks the milestones every 2 s until all pass or MAX_WAIT runs out, printing
# the seconds each took; fails the ones that did not pass and sets "slowest".
# Milestones after "--" are checked only once all before it passed (they would
# otherwise pass on the state before the outage took effect):
# run_milestones MILESTONE... [-- MILESTONE...]
run_milestones() {
    local milestones=() recovered=() i done_count=0 start=$SECONDS missing=() gate=-1 gated
    for i in "$@"; do
        if [[ "$i" == -- ]]; then
            gate=${#milestones[@]}
        else
            milestones+=("$i")
        fi
    done
    for i in "${!milestones[@]}"; do
        recovered[i]=""
    done
    while ((SECONDS - start < MAX_WAIT)) && ((done_count < ${#milestones[@]})); do
        gated=no
        if ((gate >= 0)); then
            for ((i = 0; i < gate; i++)); do
                [[ -n "${recovered[i]}" ]] || gated=yes
            done
        fi
        for i in "${!milestones[@]}"; do
            ((gate >= 0 && i >= gate)) && [[ "$gated" == yes ]] && continue
            if [[ -z "${recovered[i]}" ]] && check "${milestones[i]}"; then
                recovered[i]=$((SECONDS - start))
                done_count=$((done_count + 1))
                printf '%4ds  %s\n' "${recovered[i]}" "${milestones[i]}"
            fi
        done
        sleep 2
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
        fail "not recovered within ${MAX_WAIT}s: ${missing[*]}"
    fi
}

check_port() {
    local forwarded listen
    forwarded=$(forwarded_port)
    listen=$(listen_port)
    if [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)) && [[ "$listen" == "$forwarded" ]]; then
        echo "qBittorrent listens on Gluetun's forwarded port ($forwarded)"
    else
        fail "forwarded port '$forwarded', qBittorrent listen port '$listen'"
    fi
}

# Leak check over every sample: none may be the host's IP (or in its IPv6
# /64), and each network must have shown a VPN IP at least once, or the
# sampling proved nothing. With an OUTAGE_END epoch, each network must also
# have had a failed sample between EPOCH and it (the outage was observed):
# check_samples EPOCH [OUTAGE_END]
check_samples() {
    local verdict line
    verdict=$(python3 -I -c '
import collections, ipaddress, sys
samples_path, host_ip, host_ip6, epoch0, outage_end, *containers = sys.argv[1:]
host_net6 = ipaddress.ip_network(host_ip6 + "/64", strict=False) if host_ip6 else None
def is_host(ip):
    address = ipaddress.ip_address(ip)
    return ip == host_ip or (host_net6 is not None and address in host_net6)
counts = collections.defaultdict(collections.Counter)
seen = collections.defaultdict(set)
leaks = collections.defaultdict(list)
outage = collections.Counter()
for line in open(samples_path):
    epoch, container, ip = line.split()
    offset = int(epoch) - int(epoch0)
    if ip == "-":
        counts[container]["no answer"] += 1
        if outage_end and 0 <= offset and int(epoch) <= int(outage_end):
            outage[container] += 1
    elif is_host(ip):
        counts[container]["HOST IP"] += 1
        leaks[container].append(f"{offset:+d}s")
    else:
        counts[container]["VPN IP"] += 1
        seen[container].add(ip)
for container in containers:
    detail = ", ".join(f"{n} {kind}" for kind, n in sorted(counts[container].items())) or "none"
    ips = " ".join(sorted(seen[container])) or "none"
    print(f"INFO {container}: {sum(counts[container].values())} samples ({detail}); VPN IPs seen: {ips}")
for container, offsets in sorted(leaks.items()):
    print(f"FAIL LEAK: {len(offsets)} sample(s) from {container} left from the host IP, at " + " ".join(offsets))
for container in containers:
    if not seen[container]:
        print(f"FAIL no sample from {container} showed a VPN IP: the sampling proved nothing")
    if outage_end and not outage[container]:
        print(f"FAIL inconclusive: no sample from {container} failed during the outage")' \
        "$WORK/samples" "$host_ip" "$host_ip6" "$1" "${2:-}" "$FIREFOX" "$QBT")
    while IFS= read -r line; do
        case "$line" in
            "INFO "*) echo "${line#INFO }" ;;
            "FAIL "*) fail "${line#FAIL }" ;;
            *) fail "sample analysis: $line" ;;
        esac
    done <<<"$verdict"
}

# Scenario: the tunnel interface goes down inside Gluetun (as when the VPN
# connection drops). Gluetun's health check notices and reconnects in the same
# container, so nothing is restarted; meanwhile no traffic may leave around the
# tunnel.
scenario_tunnel_down() {
    local before after link
    precheck tunnel-down
    tun_if=$(docker exec "$VPN" printenv VPN_INTERFACE 2>/dev/null || true)
    if [[ -z "$tun_if" ]] || ! docker exec "$VPN" ip link show dev "$tun_if" >/dev/null 2>&1; then
        abort "no tunnel interface '$tun_if' in $VPN"
    fi
    before=$(started_ns "$VPN" "${SHARING[@]}" | paste -sd ' ' -)
    start_watch
    sleep "$SAMPLE_INTERVAL"
    echo "== tunnel-down: taking $tun_if down inside $VPN"
    down_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    down_epoch=$(date +%s)
    docker exec "$VPN" ip link set dev "$tun_if" down
    link=$(docker exec "$VPN" ip -o link show dev "$tun_if" 2>&1 || true)
    if [[ "$link" == *"state DOWN"* ]]; then
        echo "$tun_if is down at $(date +%T)"
    else
        fail "$tun_if did not go down: $link"
    fi
    # One sample at once, while the tunnel is surely still down.
    sample_round
    run_milestones vpn-reconnected -- tunnel-up qbittorrent-internet firefox-internet vpn-healthy \
        qbittorrent-port
    # The outage lasted until the first sample after it that got an IP (samples
    # are written as they finish, so take the earliest start).
    outage_end=$(awk -v t="$down_epoch" '$1 >= t && $3 != "-" && (min == "" || $1 < min) { min = $1 }
        END { print min }' "$WORK/samples")
    stop_watch
    echo "== tunnel-down: results"
    check_port
    check_samples "$down_epoch" "${outage_end:-$(date +%s)}"
    after=$(started_ns "$VPN" "${SHARING[@]}" | paste -sd ' ' -)
    if [[ -n "$before" && "$after" == "$before" ]]; then
        echo "no container was restarted (Gluetun reconnected in place)"
    else
        fail "containers were restarted during the tunnel outage (events: $(awk '{ print $2 ":" $3 }' "$WORK/events" | paste -sd ' ' -))"
    fi
    echo "tunnel-down: recovered after ${slowest}s"
}

# Scenario: the Gluetun container restarts. Firefox, qBittorrent and qSticky are
# left on its old, dead network until Autoheal restarts them.
scenario_restart() {
    local restart_time restart_epoch by_autoheal=0 started_list started container i events autoheal_log
    precheck restart
    start_watch
    echo "== restart: restarting $VPN"
    restart_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    restart_epoch=$(date +%s)
    docker restart "$VPN" >/dev/null
    vpn_started=$(started_ns "$VPN")
    echo "restarted $VPN at $(date +%T)"
    run_milestones firefox-web-ui firefox-internet qbittorrent-api qbittorrent-internet \
        qbittorrent-port all-rejoined
    stop_watch
    echo "== restart: results"
    check_port
    check_samples "$restart_epoch"
    # Which mechanism restarted each container sharing the VPN's network: Autoheal
    # logs each restart, and Docker records a restart event. (Compose's
    # depends_on restart applies only to docker compose commands, not to a
    # docker restart.)
    autoheal_log=$(docker logs --since "$restart_time" "$AUTOHEAL" 2>&1 || true)
    started_list=$(started_ns "${SHARING[@]}")
    [[ $(wc -w <<<"$started_list") -eq ${#SHARING[@]} ]] || fail "could not read StartedAt of: ${SHARING[*]}"
    i=0
    for started in $started_list; do
        container=${SHARING[i]}
        i=$((i + 1))
        events=$(awk -v name="$container" '$2 == name { print $3 }' "$WORK/events" | paste -sd ' ' -)
        if ((started <= vpn_started)); then
            echo "$container: not restarted (events: ${events:-none})"
        elif [[ "$autoheal_log" == *"Container /$container ("*"found to be unhealthy - Restarting"* ]]; then
            by_autoheal=$((by_autoheal + 1))
            echo "$container: restarted by Autoheal (its log; Docker events: ${events:-none})"
        else
            echo "$container: restarted, but not by Autoheal (Docker events: ${events:-none})"
        fi
    done
    if ((by_autoheal == 0)); then
        fail "Autoheal restarted none of: ${SHARING[*]}"
    fi
    echo "restart: fully recovered after ${slowest}s"
}

for scenario in "${SCENARIOS[@]}"; do
    case "$scenario" in
        tunnel-down) scenario_tunnel_down ;;
        restart) scenario_restart ;;
    esac
done

if ((failures > 0)); then
    echo "$failures failure(s)"
    exit 1
fi
echo "all scenarios passed: ${SCENARIOS[*]}"
