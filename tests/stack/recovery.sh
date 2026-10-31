#!/usr/bin/env bash
# Measures how long the stack takes to recover from a VPN container restart,
# and checks that nothing leaks around the VPN meanwhile.
#
# DISRUPTIVE: restarts the Gluetun container, which leaves Firefox, qBittorrent
# and qSticky on its old, dead network until Autoheal restarts them (Firefox's
# open tabs are lost). It first checks that the stack is healthy and leaves
# through the VPN (and aborts otherwise). Then it records how many seconds pass
# until each of these works again:
#   - Firefox's web UI from the host, and internet access from inside Firefox
#     through the VPN (not from the host's IP)
#   - qBittorrent's API from the host, and internet access from inside it
#     through the VPN
#   - qBittorrent listening on Gluetun's forwarded port
#   - every container sharing the VPN's network restarted onto the new one, and
#     every service healthy
# Throughout, it samples the public IP of Firefox's and qBittorrent's network
# every SAMPLE_INTERVAL seconds. It fails if any sample is the host's IP, if
# anything is not back within MAX_WAIT seconds, or if Autoheal restarted none of
# the containers sharing the VPN's network.
#
# Usage: tests/stack/recovery.sh [MAX_WAIT]   (default 300; needs docker, curl
# and python3; runs on bash 3.2)

set -euo pipefail

MAX_WAIT=${1:-300}
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
    printf 'ABORT %s (nothing was restarted)\n' "$*"
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
# egress_ip CONTAINER (curl where the image has it, otherwise BusyBox wget)
egress_ip() {
    local ip
    ip=$(docker exec "$1" sh -c 'if command -v curl >/dev/null 2>&1; then
            curl -s --max-time 5 https://ipinfo.io/ip
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

echo "== before the restart"
for container in "$VPN" "${SHARING[@]}"; do
    [[ "$(health "$container")" == healthy ]] || abort "$container is $(health "$container"), not healthy"
done
[[ "$(docker inspect -f '{{.State.Running}}' "$AUTOHEAL" 2>/dev/null)" == true ]] || abort "$AUTOHEAL is not running"
host_ip=""
for _ in 1 2 3; do
    host_ip=$(docker run --rm "$PLAIN_IMAGE" wget -qO- -T 10 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]') || true
    [[ "$host_ip" =~ ^[0-9.]+$ ]] && break
    host_ip=""
    sleep 3
done
[[ -n "$host_ip" ]] || abort "could not read the host's public IP"
# The host's IPv6 egress, if it has one: a sample in its /64 is a leak too.
host_ip6=$(curl -6 -s --max-time 10 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]') || host_ip6=""
for container in "$FIREFOX" "$QBT"; do
    ip=$(egress_ip "$container")
    [[ -n "$ip" && "$ip" != "$host_ip" ]] || abort "$container leaves from '$ip', not through the VPN"
    echo "$container leaves through the VPN ($ip); all containers healthy"
done

# Docker's record of what happened to the containers sharing the VPN's network.
# Lifecycle events only (health checks also show up as exec events).
docker events --filter type=container --filter "container=$FIREFOX" --filter "container=$QBT" \
    --filter "container=$QSTICKY" --filter event=kill --filter event=stop --filter event=die \
    --filter event=start --filter event=restart \
    --format '{{.TimeNano}} {{.Actor.Attributes.name}} {{.Action}}' >"$WORK/events" 2>/dev/null &
events_pid=$!

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
: >"$WORK/samples"
sampler &
sampler_pid=$!

milestones=(firefox-web-ui firefox-internet qbittorrent-api qbittorrent-internet qbittorrent-port all-rejoined)
recovered=()
for i in "${!milestones[@]}"; do
    recovered[i]=""
done

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

echo "== restart"
restart_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
restart_epoch=$(date +%s)
docker restart "$VPN" >/dev/null
start=$SECONDS
vpn_started=$(started_ns "$VPN")
echo "restarted $VPN at $(date +%T)"
done_count=0
while ((SECONDS - start < MAX_WAIT)) && ((done_count < ${#milestones[@]})); do
    for i in "${!milestones[@]}"; do
        if [[ -z "${recovered[i]}" ]] && check "${milestones[i]}"; then
            recovered[i]=$((SECONDS - start))
            done_count=$((done_count + 1))
            printf '%4ds  %s\n' "${recovered[i]}" "${milestones[i]}"
        fi
    done
    sleep 2
done
touch "$WORK/stop"
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=""
# One more sample of each network, now that everything should be back.
sample_round
sleep 1
kill "$events_pid" 2>/dev/null || true
wait "$events_pid" 2>/dev/null || true
events_pid=""

echo "== results"
missing=()
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
forwarded=$(forwarded_port)
listen=$(listen_port)
if [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)) && [[ "$listen" == "$forwarded" ]]; then
    echo "qBittorrent listens on Gluetun's forwarded port ($forwarded)"
else
    fail "forwarded port '$forwarded', qBittorrent listen port '$listen'"
fi

# Leak check over every sample: none may be the host's IP (or in its IPv6
# /64), and each network must have shown a VPN IP at least once, or the
# sampling proved nothing.
sample_verdict=$(python3 -I -c '
import collections, ipaddress, sys
samples_path, host_ip, host_ip6, restart_epoch, *containers = sys.argv[1:]
host_net6 = ipaddress.ip_network(host_ip6 + "/64", strict=False) if host_ip6 else None
def is_host(ip):
    address = ipaddress.ip_address(ip)
    return ip == host_ip or (host_net6 is not None and address in host_net6)
counts = collections.defaultdict(collections.Counter)
seen = collections.defaultdict(set)
leaks = collections.defaultdict(list)
for line in open(samples_path):
    epoch, container, ip = line.split()
    offset = int(epoch) - int(restart_epoch)
    if ip == "-":
        counts[container]["no answer"] += 1
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
        print(f"FAIL no sample from {container} showed a VPN IP: the sampling proved nothing")' \
    "$WORK/samples" "$host_ip" "$host_ip6" "$restart_epoch" "$FIREFOX" "$QBT")
while IFS= read -r line; do
    case "$line" in
        "INFO "*) echo "${line#INFO }" ;;
        "FAIL "*) fail "${line#FAIL }" ;;
        *) fail "sample analysis: $line" ;;
    esac
done <<<"$sample_verdict"

# Which mechanism restarted each container sharing the VPN's network: Autoheal
# logs each restart, and Docker records a restart event. (Compose's
# depends_on restart applies only to docker compose commands, not to a
# docker restart.)
autoheal_log=$(docker logs --since "$restart_time" "$AUTOHEAL" 2>&1 || true)
by_autoheal=0
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

if ((failures > 0)); then
    echo "$failures failure(s)"
    exit 1
fi
echo "fully recovered after ${slowest}s"
