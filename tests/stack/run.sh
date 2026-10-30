#!/usr/bin/env bash
# End-to-end test of the running stack (docker compose up -d first).
#
# Checks real behavior, not just container status:
#   - every service runs the image docker-compose.yml pins, and is healthy
#   - traffic from all three VPN-routed containers leaves through the VPN
#     (same public IP, different from the host's), and the kill switch drops
#     traffic forced around the tunnel
#   - DNS goes through Gluetun and resolves
#   - Gluetun's forwarded port is qBittorrent's listening port, and qSticky
#     restores it after it is changed
#   - qBittorrent's WebUI, API and settings, and the .torrent watch-folder
#     hand-off (a private, tracker-less test torrent: no network contact)
#   - the Firefox web UI, private browsing and the single window
#   - Autoheal restarts an unhealthy container labeled autoheal=true and leaves
#     an unlabeled one alone
#
# It changes nothing permanently: the listening port is restored by qSticky
# (or by this script), and the test torrent and test containers are removed.
#
# Usage: tests/stack/run.sh   (needs docker, python3 and curl on the host)

set -euo pipefail

STACK_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$STACK_DIR/../.." && pwd)
PLAIN_IMAGE=alpine:3.24
QBT_URL=http://localhost:9080
FIREFOX_URL=http://localhost:5800
HEALTH_TIMEOUT=360
WORK=$(mktemp -d)
TEST_ID="stack-test-$$"

failures=0
checks=0
restore_port=""
watch_file=""
test_hash=""

pass() {
    checks=$((checks + 1))
    printf 'ok    %s\n' "$*"
}
fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf 'FAIL  %s\n' "$*"
}

cleanup() {
    docker rm -f "$TEST_ID-labeled" "$TEST_ID-unlabeled" >/dev/null 2>&1 || true
    if [[ -n "$watch_file" ]]; then
        rm -f "$watch_file"
    fi
    if [[ -n "$test_hash" ]]; then
        curl -s --max-time 10 -X POST "$QBT_URL/api/v2/torrents/delete" \
            --data "hashes=$test_hash&deleteFiles=true" >/dev/null || true
    fi
    if [[ -n "$restore_port" ]]; then
        set_listen_port "$restore_port" || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

docker compose -f "$REPO/docker-compose.yml" config --format json > "$WORK/config.json"

# Prints a value from the resolved compose config: compose_value SERVICE KEY
# where KEY is "container", "image", "env:<NAME>" or "mount:<target>".
compose_value() {
    python3 -I - "$WORK/config.json" "$1" "$2" <<'EOF'
import json, sys
config_path, service, key = sys.argv[1:]
svc = json.load(open(config_path))["services"][service]
if key == "container":
    print(svc["container_name"])
elif key == "image":
    print(svc["image"])
elif key.startswith("env:"):
    print(svc.get("environment", {}).get(key[4:], ""))
elif key.startswith("mount:"):
    print(next(v["source"] for v in svc.get("volumes", []) if v["target"] == key[6:]))
EOF
}

# Prints the JSON value at a dotted path from stdin: json_get PATH
json_get() {
    python3 -I -c '
import json, sys
value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[part]
print(json.dumps(value) if isinstance(value, (dict, list)) else value)' "$1"
}

# Runs a command until it prints an IP address (3 tries); prints the address.
public_ip() {
    local ip
    for _ in 1 2 3; do
        ip=$("$@" 2>/dev/null | tr -d '[:space:]') || true
        if [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
            echo "$ip"
            return 0
        fi
        sleep 3
    done
    return 1
}

qbt_preferences() { curl -s --max-time 10 "$QBT_URL/api/v2/app/preferences"; }
# Sets qBittorrent's listening port; fails unless the API answers HTTP 200.
set_listen_port() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
        "$QBT_URL/api/v2/app/setPreferences" --data-urlencode "json={\"listen_port\": $1}")
    [[ "$code" == 200 ]]
}

VPN=$(compose_value vpn container)
QBT=$(compose_value qbittorrent container)
QSTICKY=$(compose_value qsticky container)
FIREFOX=$(compose_value firefox container)
AUTOHEAL=$(compose_value autoheal container)
FIREFOX_UID=$(compose_value firefox env:USER_ID)
# qSticky's Gluetun API key, for the control server checks (never printed).
GLUETUN_API_KEY=$(compose_value qsticky env:GLUETUN_APIKEY)
export GLUETUN_API_KEY

echo "== containers run the pinned images and are healthy"
for service in vpn qbittorrent qsticky firefox autoheal; do
    container=$(compose_value "$service" container)
    pinned=$(compose_value "$service" image)
    running=$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || echo "(not running)")
    if [[ "$running" == "$pinned" ]]; then
        pass "$service runs $pinned"
    else
        fail "$service runs $running, docker-compose.yml pins $pinned"
    fi
done
deadline=$((SECONDS + HEALTH_TIMEOUT))
for container in "$VPN" "$QBT" "$QSTICKY" "$FIREFOX"; do
    status=""
    while ((SECONDS < deadline)); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)
        [[ "$status" == healthy ]] && break
        sleep 5
    done
    if [[ "$status" == healthy ]]; then
        pass "$container is healthy"
    else
        fail "$container is $status after waiting up to ${HEALTH_TIMEOUT}s"
    fi
done
if [[ "$(docker inspect -f '{{.State.Running}}' "$AUTOHEAL" 2>/dev/null)" == true ]]; then
    pass "$AUTOHEAL is running"
else
    fail "$AUTOHEAL is not running"
fi

echo "== VPN egress and kill switch"
host_ip=$(public_ip docker run --rm "$PLAIN_IMAGE" wget -qO- -T 10 https://ipinfo.io/ip) || host_ip=""
vpn_ip=$(public_ip docker exec "$VPN" wget -qO- -T 10 https://ipinfo.io/ip) || vpn_ip=""
qbt_ip=$(public_ip docker exec "$QBT" curl -s --max-time 10 https://ipinfo.io/ip) || qbt_ip=""
firefox_ip=$(public_ip docker exec "$FIREFOX" wget -qO- -T 10 https://ipinfo.io/ip) || firefox_ip=""
if [[ -n "$host_ip" && -n "$vpn_ip" && "$vpn_ip" != "$host_ip" ]]; then
    pass "VPN public IP $vpn_ip differs from the host's"
else
    fail "VPN public IP '$vpn_ip' vs host '$host_ip'"
fi
if [[ -n "$vpn_ip" && "$qbt_ip" == "$vpn_ip" && "$firefox_ip" == "$vpn_ip" ]]; then
    pass "qBittorrent and Firefox leave through the VPN ($vpn_ip)"
else
    fail "egress IPs: vpn '$vpn_ip', qbittorrent '$qbt_ip', firefox '$firefox_ip'"
fi
route=$(docker exec "$VPN" ip route get 1.1.1.1 2>&1 || true)
if [[ "$route" == *" dev tun0 "* ]]; then
    pass "default route goes through the tunnel (tun0)"
else
    fail "route to 1.1.1.1: $route"
fi
# Capture before matching: grep -q exits early, and pipefail would then see a
# broken pipe from the command feeding it.
output_rules=$(docker exec "$VPN" iptables -S OUTPUT 2>/dev/null || true)
if grep -qx -- '-P OUTPUT DROP' <<<"$output_rules"; then
    pass "firewall drops outgoing traffic by default"
else
    fail "firewall OUTPUT policy is not DROP"
fi
if docker exec "$VPN" ping -c 1 -W 3 -I eth0 1.1.1.1 >/dev/null 2>&1; then
    fail "kill switch: traffic forced out eth0 (around the tunnel) got through"
else
    pass "kill switch: traffic forced out eth0 (around the tunnel) is dropped"
fi

echo "== DNS"
for container in "$QBT" "$FIREFOX"; do
    if docker exec "$container" grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf &&
        docker exec "$container" getent hosts example.com >/dev/null 2>&1; then
        pass "$container resolves names through Gluetun's DNS (127.0.0.1)"
    else
        fail "$container DNS: $(docker exec "$container" grep nameserver /etc/resolv.conf | paste -sd ' ' -)"
    fi
done

echo "== port forwarding and qSticky"
vpn_status=$(docker exec -e GLUETUN_API_KEY "$QBT" sh -c \
    'curl -s --max-time 10 -H "X-API-Key: $GLUETUN_API_KEY" http://localhost:8000/v1/vpn/status' \
    2>/dev/null | json_get status 2>/dev/null || true)
if [[ "$vpn_status" == running ]]; then
    pass "Gluetun control server reports the VPN running (API key accepted)"
else
    fail "Gluetun /v1/vpn/status: '$vpn_status'"
fi
# The control server must refuse requests without the right API key.
for route in /v1/portforward /v1/vpn/status; do
    for key in none wrong; do
        header=""
        [[ "$key" == wrong ]] && header="X-API-Key: wrong-$TEST_ID"
        code=$(docker exec "$QBT" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            ${header:+-H "$header"} "http://localhost:8000$route" 2>/dev/null || true)
        if [[ "$code" == 401 ]]; then
            pass "Gluetun control server refuses $route with $key API key (401)"
        else
            fail "Gluetun control server answered $route with $key API key: HTTP $code"
        fi
    done
done
forwarded=$(docker exec -e GLUETUN_API_KEY "$QBT" sh -c \
    'curl -s --max-time 10 -H "X-API-Key: $GLUETUN_API_KEY" http://localhost:8000/v1/portforward' \
    2>/dev/null | json_get port 2>/dev/null || echo 0)
listen=$(qbt_preferences | json_get listen_port 2>/dev/null || echo "")
if [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)) && [[ "$listen" == "$forwarded" ]]; then
    pass "qBittorrent listens on Gluetun's forwarded port ($forwarded)"
else
    fail "forwarded port '$forwarded', qBittorrent listen port '$listen'"
fi
# qSticky's log since it started: it logged in to qBittorrent, and any error
# (for example while qBittorrent was restarting) was followed by a successful
# login or port update. qBittorrent 5.2+ answers login with 204, which older
# qSticky rejected: that shows as errors with no success after them.
qsticky_log=$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$QSTICKY")" "$QSTICKY" 2>&1 || true)
qsticky_verdict=$(python3 -I -c '
import re, sys
lines = sys.stdin.read().splitlines()
error = re.compile(r" - (ERROR|CRITICAL) - |Login failed")
success = re.compile(r"Successfully (logged in to qBittorrent|updated port)|already set correctly")
errors = [i for i, line in enumerate(lines) if error.search(line)]
successes = [i for i, line in enumerate(lines) if success.search(line)]
if not any("Successfully logged in to qBittorrent" in line for line in lines):
    print("FAIL no successful login to qBittorrent")
elif errors and not any(i > errors[-1] for i in successes):
    print("FAIL " + lines[errors[-1]])
else:
    print(f"OK {len(errors)}")' <<<"$qsticky_log")
if [[ "$qsticky_verdict" == "OK 0" ]]; then
    pass "qSticky logged in to qBittorrent with no errors since it started"
elif [[ "$qsticky_verdict" == OK* ]]; then
    pass "qSticky logged in to qBittorrent; it recovered from ${qsticky_verdict#OK } error(s)"
else
    fail "qSticky log: ${qsticky_verdict#FAIL }"
fi
if [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)); then
    check_interval=$(compose_value qsticky env:CHECK_INTERVAL)
    wrong_port=$((forwarded < 65535 ? forwarded + 1 : forwarded - 1))
    restore_port=$forwarded
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # qSticky may correct the port within moments of the change (it checks every
    # CHECK_INTERVAL seconds), so its own log line is the evidence, together with
    # the port being back afterward.
    restored=""
    if set_listen_port "$wrong_port"; then
        wait_until=$((SECONDS + ${check_interval:-30} * 2 + 30))
        while ((SECONDS < wait_until)); do
            listen=$(qbt_preferences | json_get listen_port 2>/dev/null || echo "")
            qsticky_log=$(docker logs --since "$since" "$QSTICKY" 2>&1 || true)
            if [[ "$listen" == "$forwarded" &&
                "$qsticky_log" == *"Port change needed: $wrong_port -> $forwarded"* ]]; then
                restored=yes
                break
            fi
            sleep 3
        done
        if [[ "$restored" == yes ]]; then
            pass "qSticky restored the listening port ($wrong_port -> $forwarded)"
            restore_port=""
        else
            fail "qSticky did not restore the port (set $wrong_port; now '$listen')"
        fi
    else
        fail "could not set qBittorrent's listening port through its API"
    fi
else
    fail "qSticky check skipped: no forwarded port"
fi

echo "== qBittorrent"
version=$(curl -s --max-time 10 "$QBT_URL/api/v2/app/version" || true)
if [[ "$version" =~ ^v[0-9]+\. ]]; then
    pass "WebUI API answers from the host without a password ($version)"
else
    fail "WebUI API at $QBT_URL: '$version'"
fi
settings=$(qbt_preferences | python3 -I "$STACK_DIR/qbt_settings.py" 2>&1 || true)
if [[ -z "$settings" ]]; then
    pass "download paths, /watch folder and UPnP off as the init script sets them"
else
    fail "qBittorrent settings: $settings"
fi
watch_dir=$(compose_value qbittorrent mount:/watch)
test_hash=$(python3 -I "$STACK_DIR/torrent_file.py" "$WORK/test.torrent" "$TEST_ID")
watch_file="$watch_dir/$TEST_ID.torrent"
cp "$WORK/test.torrent" "$watch_file"
added=""
for _ in $(seq 1 30); do
    torrents=$(curl -s --max-time 10 "$QBT_URL/api/v2/torrents/info?hashes=$test_hash" || true)
    if [[ "$torrents" == *"$test_hash"* ]]; then
        added=yes
        break
    fi
    sleep 2
done
if [[ "$added" == yes ]]; then
    pass "a .torrent dropped in the watch folder was added"
else
    fail "a .torrent dropped in the watch folder was not added within 60s"
fi

echo "== Firefox"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$FIREFOX_URL/" || true)
if [[ "$code" == 200 ]]; then
    pass "web UI answers at $FIREFOX_URL"
else
    fail "web UI at $FIREFOX_URL: HTTP $code"
fi
if docker exec "$FIREFOX" grep -qxF 'user_pref("browser.privatebrowsing.autostart", true);' \
    /config/profile/prefs.js; then
    pass "private browsing is set to always on"
else
    fail "prefs.js does not set browser.privatebrowsing.autostart to true"
fi
windows=$(docker exec -u "$FIREFOX_UID" -e DISPLAY=:0 "$FIREFOX" \
    xdotool search --onlyvisible --classname Navigator 2>/dev/null | wc -l | tr -d ' ')
if [[ "$windows" == 1 ]]; then
    pass "Firefox shows exactly one window"
else
    fail "Firefox shows $windows windows"
fi

echo "== Autoheal"
start_period=$(compose_value autoheal env:AUTOHEAL_START_PERIOD)
interval=$(compose_value autoheal env:AUTOHEAL_INTERVAL)
uptime=$(python3 -I -c '
import datetime, sys
started = datetime.datetime.fromisoformat(sys.argv[1][:26].rstrip("Z") + "+00:00")
print(int((datetime.datetime.now(datetime.timezone.utc) - started).total_seconds()))' \
    "$(docker inspect -f '{{.State.StartedAt}}' "$AUTOHEAL")")
if ((uptime < ${start_period:-0} + ${interval:-5})); then
    wait_for=$((${start_period:-0} + ${interval:-5} - uptime))
    echo "      autoheal started ${uptime}s ago; waiting ${wait_for}s for its start period"
    sleep "$wait_for"
fi
for kind in labeled unlabeled; do
    labels=()
    [[ "$kind" == labeled ]] && labels=(--label autoheal=true)
    docker run -d --name "$TEST_ID-$kind" --network none ${labels[@]+"${labels[@]}"} \
        --health-cmd false --health-interval 2s --health-retries 1 --health-start-period 0s \
        "$PLAIN_IMAGE" sleep 600 >/dev/null
done
labeled_start=$(docker inspect -f '{{.State.StartedAt}}' "$TEST_ID-labeled")
unlabeled_start=$(docker inspect -f '{{.State.StartedAt}}' "$TEST_ID-unlabeled")
restarted=""
wait_until=$((SECONDS + ${interval:-5} * 3 + 30))
while ((SECONDS < wait_until)); do
    if [[ "$(docker inspect -f '{{.State.StartedAt}}' "$TEST_ID-labeled")" != "$labeled_start" ]]; then
        restarted=yes
        break
    fi
    sleep 2
done
unlabeled_health=$(docker inspect -f '{{.State.Health.Status}}' "$TEST_ID-unlabeled")
if [[ "$restarted" == yes ]]; then
    pass "restarted an unhealthy container labeled autoheal=true"
else
    fail "did not restart an unhealthy container labeled autoheal=true"
fi
if [[ "$(docker inspect -f '{{.State.StartedAt}}' "$TEST_ID-unlabeled")" == "$unlabeled_start" &&
    "$unlabeled_health" == unhealthy ]]; then
    pass "left an unhealthy unlabeled container alone"
else
    fail "unlabeled test container was restarted or not unhealthy ($unlabeled_health)"
fi

if ((failures > 0)); then
    echo "$failures of $checks check(s) failed"
    exit 1
fi
echo "all $checks checks passed"
