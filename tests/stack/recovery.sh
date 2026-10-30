#!/usr/bin/env bash
# Measures how long the stack takes to recover from a VPN container restart.
#
# DISRUPTIVE: restarts the Gluetun container, which leaves Firefox, qBittorrent
# and qSticky on its old, dead network until Autoheal restarts them (Firefox's
# open tabs are lost). Then it records how many seconds pass until each of
# these works again:
#   - Firefox's web UI from the host, and internet access from inside Firefox
#   - qBittorrent's API from the host, and internet access from inside it
#   - every container sharing the VPN's network restarted onto the new one, and
#     every service healthy
# and fails if anything is not back within MAX_WAIT seconds.
#
# Usage: tests/stack/recovery.sh [MAX_WAIT]   (default 300; needs docker, curl)

set -euo pipefail

MAX_WAIT=${1:-300}
VPN=gluetun-vpn
FIREFOX=firefox-novnc
QBT=qbittorrent
QSTICKY=qsticky

declare -A recovered=()
milestones=(firefox-web-ui firefox-internet qbittorrent-api qbittorrent-internet all-rejoined)

check() {
    case "$1" in
        firefox-web-ui)
            [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:5800/)" == 200 ]]
            ;;
        firefox-internet)
            docker exec "$FIREFOX" wget -q -O /dev/null -T 5 https://ipinfo.io/ip 2>/dev/null
            ;;
        qbittorrent-api)
            [[ "$(curl -s --max-time 3 http://localhost:9080/api/v2/app/version)" == v* ]]
            ;;
        qbittorrent-internet)
            docker exec "$QBT" curl -s -o /dev/null --max-time 5 https://ipinfo.io/ip 2>/dev/null
            ;;
        all-rejoined)
            # Every container sharing the VPN's network was restarted after the VPN (so
            # it is on the new network) and is healthy, and the VPN is healthy. Health
            # alone means little here: right after the restart, all still report healthy.
            local container
            [[ "$(docker inspect -f '{{.State.Health.Status}}' "$VPN")" == healthy ]] || return 1
            for container in "$FIREFOX" "$QBT" "$QSTICKY"; do
                [[ "$(docker inspect -f '{{.State.StartedAt}}' "$container")" > "$vpn_started" &&
                    "$(docker inspect -f '{{.State.Health.Status}}' "$container")" == healthy ]] || return 1
            done
            ;;
    esac
}

docker restart "$VPN" >/dev/null
start=$SECONDS
vpn_started=$(docker inspect -f '{{.State.StartedAt}}' "$VPN")
echo "restarted $VPN at $(date +%T)"
while ((SECONDS - start < MAX_WAIT)) && ((${#recovered[@]} < ${#milestones[@]})); do
    for milestone in "${milestones[@]}"; do
        if [[ -z "${recovered[$milestone]:-}" ]] && check "$milestone"; then
            recovered[$milestone]=$((SECONDS - start))
            printf '%4ds  %s\n' "${recovered[$milestone]}" "$milestone"
        fi
    done
    sleep 2
done

restarted=$(docker logs --since "$((SECONDS - start + 5))s" autoheal 2>&1 |
    grep -oE '/(firefox-novnc|qbittorrent|qsticky|gluetun-vpn) ' | tr -d '/ ' | sort -u | paste -sd ' ' -)
echo "autoheal restarted: ${restarted:-nothing}"
missing=()
for milestone in "${milestones[@]}"; do
    [[ -n "${recovered[$milestone]:-}" ]] || missing+=("$milestone")
done
if ((${#missing[@]} > 0)); then
    echo "FAIL  not recovered within ${MAX_WAIT}s: ${missing[*]}"
    exit 1
fi
slowest=0
for milestone in "${milestones[@]}"; do
    ((recovered[$milestone] > slowest)) && slowest=${recovered[$milestone]}
done
echo "fully recovered after ${slowest}s"
