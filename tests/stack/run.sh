#!/usr/bin/env bash
# End-to-end test of the running stack (docker compose up -d first).
#
# Checks real behavior, not just container status:
#   - every service runs the image docker-compose.yml pins, and is healthy;
#     Autoheal's image, built here, has the labels of the commit and base image
#     docker-compose.yml builds it from
#   - the web UIs are published on 127.0.0.1 only: they answer at localhost,
#     but not at this computer's LAN address or any other address it has
#   - traffic from all three VPN-routed containers leaves through the VPN
#     (same public IP, different from the host's), and the kill switch drops
#     TCP and ICMP forced around the tunnel (while the same probes through the
#     tunnel get through); the firewall lets out of the bypassed interface only
#     UDP to the WireGuard endpoint
#   - IPv6: the firewall drops it by default, and IPv6 egress from the VPN's
#     network fails (or leaves through the tunnel), never from the host's
#   - DNS goes through Gluetun and resolves; Gluetun forwards it over DNS over
#     TLS through the tunnel, and the outside world sees the TLS provider's
#     resolver, not the host's
#   - Gluetun's forwarded port is qBittorrent's listening port, and qSticky
#     restores it after it is changed; Gluetun runs with only NET_ADMIN and
#     NET_RAW, and still writes the port to its status file, as root's
#   - Gluetun's control server refuses requests without the right API key, and
#     with qSticky's valid key refuses (read-only) routes outside its role; it
#     reads that role from the file Compose writes from GLUETUN_API_KEY
#   - qBittorrent's WebUI, API and settings, and the .torrent watch-folder
#     hand-off (a private, tracker-less test torrent: no network contact)
#   - qBittorrent's Host-header check (the DNS rebinding defense) refuses any
#     name but localhost and 127.0.0.1, and its clients' URLs still work
#   - the Firefox web UI (serving the patched noVNC files, ui.js with the
#     content hash that busts caches), private browsing as FIREFOX_PRIVATE_BROWSING
#     in .env sets it, and the single window
#   - Autoheal reaches Docker only through its socket proxy, which lets it list
#     containers and restart one, and refuses everything else (create, inspect,
#     exec, stop)
#   - Autoheal restarts an unhealthy container labeled autoheal=true and leaves
#     an unlabeled one alone; its restart call waits for a restart that takes
#     the whole stop timeout (the proxy logs 204, and Autoheal logs no failure)
#
# It changes nothing permanently: the listening port is restored by qSticky
# (or by this script), and the test torrent and test containers are removed.
#
# Usage: tests/stack/run.sh   (needs docker, python3 and curl on the host)

set -euo pipefail

STACK_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$STACK_DIR/../.." && pwd)
# A plain container on Docker's default network (the host's path out). Pinned
# by tag and multi-arch index digest, like docker-compose.yml's images; to
# update: docker buildx imagetools inspect alpine:<tag> (the top "Digest:").
PLAIN_IMAGE=alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
# Services that answer with the caller's public IP, in order of preference;
# the second is the fallback when the first fails or rate-limits.
IP_SERVICES="https://ipinfo.io/ip https://api.ipify.org"
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
    docker rm -f "$TEST_ID-labeled" "$TEST_ID-unlabeled" "$TEST_ID-proxy-target" \
        "$TEST_ID-created" >/dev/null 2>&1 || true
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
# where KEY is "container", "image", "env:<NAME>", "mount:<target>",
# "build-label:<NAME>" (a label of the image the service builds) or
# "config-target:<NAME>" (where the top-level config NAME is put in the
# container). Prints nothing for a service the file lacks (the checks on it
# then fail).
compose_value() {
    python3 -I - "$WORK/config.json" "$1" "$2" <<'EOF'
import json, sys
config_path, service, key = sys.argv[1:]
svc = json.load(open(config_path))["services"].get(service, {})
if key == "container":
    print(svc.get("container_name", ""))
elif key == "image":
    print(svc.get("image", ""))
elif key.startswith("env:"):
    print(svc.get("environment", {}).get(key[4:], ""))
elif key.startswith("mount:"):
    print(next(v["source"] for v in svc.get("volumes", []) if v["target"] == key[6:]))
elif key.startswith("build-label:"):
    print(svc.get("build", {}).get("labels", {}).get(key[12:], ""))
elif key.startswith("config-target:"):
    print(next((c.get("target", "") for c in svc.get("configs", []) if c.get("source") == key[14:]), ""))
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
retry_ip() {
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
# Runs a fetch command with each IP service URL appended, until one prints an
# IP address (3 rounds); prints the address: public_ip COMMAND...
public_ip() {
    local ip url
    for _ in 1 2 3; do
        for url in $IP_SERVICES; do
            ip=$("$@" "$url" 2>/dev/null | tr -d '[:space:]') || true
            if [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]]; then
                echo "$ip"
                return 0
            fi
        done
        sleep 3
    done
    return 1
}

# A DNS TXT query over UDP with the Python standard library (the images have no
# dig): python3 -I -c "$DNS_TXT_PY" NAME SERVER prints one line per TXT record.
DNS_TXT_PY='
import random, socket, struct, sys
name, server = sys.argv[1:]
qid = random.randrange(65536)
query = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + b"".join(
    bytes([len(label)]) + label.encode() for label in name.rstrip(".").split(".")
) + b"\0" + struct.pack(">HH", 16, 1)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(5)
    sock.sendto(query, (server, 53))
    data = sock.recv(4096)
rid, flags, questions, answers = struct.unpack(">HHHH", data[:8])
if rid != qid or flags & 0x000F:
    sys.exit(f"bad answer: id {rid}, rcode {flags & 0x000F}")
def skip_name(i):
    while data[i]:
        if data[i] & 0xC0 == 0xC0:
            return i + 2
        i += data[i] + 1
    return i + 1
i = 12
for _ in range(questions):
    i = skip_name(i) + 4
for _ in range(answers):
    i = skip_name(i)
    rtype, _, _, length = struct.unpack(">HHIH", data[i:i + 10])
    i += 10
    if rtype == 16:
        j, strings = i, []
        while j < i + length:
            strings.append(data[j + 1:j + 1 + data[j]].decode())
            j += data[j] + 1
        print(" ".join(strings))
    i += length'
# TXT records of NAME as seen through Gluetun's DNS from qBittorrent (the VPN's
# network), or through the host's resolver: txt_lookup vpn|host NAME
txt_lookup() {
    if [[ "$1" == vpn ]]; then
        docker exec "$QBT" python3 -I -c "$DNS_TXT_PY" "$2" 127.0.0.1
    else
        python3 -I -c "$DNS_TXT_PY" "$2" "$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ { print $2; exit }' /etc/resolv.conf)"
    fi
}
# The autonomous system number announcing an IPv4 or IPv6 address (Team
# Cymru's DNS service, asked through the same path): asn_of vpn|host IP
asn_of() {
    local name
    name=$(python3 -I -c '
import ipaddress, sys
address = ipaddress.ip_address(sys.argv[1])
zone = "origin.asn.cymru.com" if address.version == 4 else "origin6.asn.cymru.com"
print(address.reverse_pointer.rsplit(".", 2)[0] + "." + zone)' "$2") || return 1
    txt_lookup "$1" "$name" | awk -F' [|] ' 'NR == 1 { print $1 }'
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
PROXY=$(compose_value autoheal-proxy container)
FIREFOX_UID=$(compose_value firefox env:USER_ID)
# qSticky's Gluetun API key, for the control server checks (never printed).
GLUETUN_API_KEY=$(compose_value qsticky env:GLUETUN_APIKEY)
export GLUETUN_API_KEY

echo "== containers run the pinned images and are healthy"
for service in vpn qbittorrent qsticky firefox autoheal autoheal-proxy; do
    container=$(compose_value "$service" container)
    pinned=$(compose_value "$service" image)
    # (docker inspect prints an empty line for a container that does not exist)
    running=$(docker inspect -f '{{.Config.Image}}' "${container:-none}" 2>/dev/null) ||
        running="(not running)"
    if [[ "$running" == "$pinned" ]]; then
        pass "$service runs $pinned"
    else
        fail "$service runs $running, docker-compose.yml pins $pinned"
    fi
done
# Autoheal's image is built here, so its name is only a local tag: an image
# built earlier from other inputs under the same name would pass the check
# above. Its labels record the commit and base image it was built from.
autoheal_image=$(docker inspect -f '{{.Image}}' "${AUTOHEAL:-none}" 2>/dev/null) || autoheal_image=""
for label in org.opencontainers.image.revision org.opencontainers.image.base.digest; do
    want=$(compose_value autoheal "build-label:$label")
    have=$(docker image inspect -f "{{index .Config.Labels \"$label\"}}" \
        "${autoheal_image:-none}" 2>/dev/null) || have=""
    if [[ -n "$want" && "$have" == "$want" ]]; then
        pass "autoheal's image has $label=$want"
    else
        fail "autoheal's image has $label='$have', docker-compose.yml builds it with '$want'"
    fi
done
deadline=$((SECONDS + HEALTH_TIMEOUT))
for container in "$VPN" "$QBT" "$QSTICKY" "$FIREFOX" "${AUTOHEAL:-autoheal}" \
    "${PROXY:-autoheal-proxy}"; do
    status=""
    while ((SECONDS < deadline)); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null) ||
            status=missing
        [[ "$status" == healthy ]] && break
        sleep 5
    done
    if [[ "$status" == healthy ]]; then
        pass "$container is healthy"
    else
        fail "$container is $status after waiting up to ${HEALTH_TIMEOUT}s"
    fi
done

echo "== published ports (loopback only)"
# The web UIs have no password, so only this computer may reach them: every
# port docker-compose.yml publishes must be bound to 127.0.0.1, and nothing else.
bindings=$(docker port "$VPN" 2>/dev/null || true)
bindings_verdict=$(python3 -I -c '
import json, sys
config_path, bindings = sys.argv[1:]
ports = json.load(open(config_path))["services"]["vpn"].get("ports", [])
wanted = {"%s/%s -> 127.0.0.1:%s" % (p["target"], p.get("protocol", "tcp"), p["published"]) for p in ports}
actual = {line.strip() for line in bindings.splitlines() if line.strip()}
if not wanted:
    print("FAIL docker-compose.yml publishes no ports for the vpn service")
elif actual != wanted:
    print("FAIL bindings " + (" | ".join(sorted(actual)) or "none") + "; want " + " | ".join(sorted(wanted)))
else:
    print("OK " + ", ".join(sorted(actual)))' "$WORK/config.json" "$bindings" 2>&1 || true)
if [[ "$bindings_verdict" == OK* ]]; then
    pass "published ports are bound to 127.0.0.1 only: ${bindings_verdict#OK }"
else
    fail "published ports: ${bindings_verdict#FAIL }"
fi
# This computer's own addresses other than loopback (IPv4, and IPv6 except
# link-local): the LAN address first (the source of the route to 1.1.1.1; a UDP
# connect sends nothing), then every other interface address.
host_addresses=$(python3 -I -c '
import ipaddress, re, shutil, socket, subprocess
found = []
try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("1.1.1.1", 53))
        found.append(s.getsockname()[0])
except OSError:
    pass
if shutil.which("ifconfig"):
    text = subprocess.run(["ifconfig", "-a"], capture_output=True, text=True).stdout
    candidates = re.findall(r"\binet6? (?:addr:)?([0-9a-fA-F.:]+)", text)
else:
    text = subprocess.run(["ip", "-o", "addr", "show"], capture_output=True, text=True).stdout
    candidates = [c.split("/")[0] for c in re.findall(r"\binet6? (\S+)", text)]
for candidate in candidates:
    address = ipaddress.ip_address(candidate)
    if not (address.is_loopback or address.is_link_local) and candidate not in found:
        found.append(candidate)
print(" ".join(found))')
lan_ip=${host_addresses%% *}
# Prints curl's exit code and HTTP status for a URL: probe_url URL
probe_url() {
    local rc=0 code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null) || rc=$?
    echo "$rc $code"
}
for web_ui in "Firefox $FIREFOX_URL/ 5800" "qBittorrent $QBT_URL/api/v2/app/version 9080"; do
    read -r ui_name ui_url ui_port <<<"$web_ui"
    local_result=$(probe_url "$ui_url")
    reached=()
    for address in $host_addresses; do
        [[ "$address" == *:* ]] && address="[$address]"
        result=$(probe_url "${ui_url/localhost:$ui_port/$address:$ui_port}")
        # curl exit 7: connection refused; 28: timed out. Anything else got an answer.
        [[ "$result" == "7 000" || "$result" == "28 000" ]] || reached+=("$address ($result)")
    done
    if [[ -z "$lan_ip" ]]; then
        fail "$ui_name: inconclusive, this computer has no LAN address to test from"
    elif [[ "$local_result" != "0 200" ]]; then
        fail "$ui_name: inconclusive, $ui_url itself does not answer 200 (curl exit and status: $local_result)"
    elif ((${#reached[@]} > 0)); then
        fail "$ui_name port $ui_port answers on this computer's non-loopback address(es): ${reached[*]}"
    else
        others=$(($(wc -w <<<"$host_addresses") - 1))
        pass "$ui_name answers at localhost:$ui_port, not at the LAN address $lan_ip or this computer's $others other non-loopback address(es)"
    fi
done

echo "== VPN egress and kill switch"
host_ip=$(public_ip docker run --rm "$PLAIN_IMAGE" wget -qO- -T 10) || host_ip=""
vpn_ip=$(public_ip docker exec "$VPN" wget -qO- -T 10) || vpn_ip=""
qbt_ip=$(public_ip docker exec "$QBT" curl -s --max-time 10) || qbt_ip=""
firefox_ip=$(public_ip docker exec "$FIREFOX" wget -qO- -T 10) || firefox_ip=""
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
# The tunnel interface as the running Gluetun names it (VPN_INTERFACE; the
# image sets it, the WireGuard code default differs), and the interface the
# tunnel bypasses: the one the main table's default route uses.
tun_if=$(docker exec "$VPN" printenv VPN_INTERFACE 2>/dev/null || true)
bypass_if=$(docker exec "$VPN" ip -o route show default table main 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' || true)
bypass_cidr=$(docker exec "$VPN" ip -o -4 addr show dev "${bypass_if:-none}" 2>/dev/null |
    awk '{ print $4; exit }' || true)
if [[ -n "$tun_if" ]] && docker exec "$VPN" ip link show dev "$tun_if" >/dev/null 2>&1 &&
    [[ -n "$bypass_if" && "$bypass_if" != "$tun_if" && -n "$bypass_cidr" ]]; then
    pass "tunnel interface $tun_if exists; the tunnel bypasses $bypass_if ($bypass_cidr)"
else
    fail "tunnel interface '$tun_if' or bypassed interface '$bypass_if' ('$bypass_cidr') not found"
fi
route=$(docker exec "$VPN" ip route get 1.1.1.1 2>&1 || true)
if [[ -n "$tun_if" && "$route" == *" dev $tun_if "* ]]; then
    pass "default route goes through the tunnel ($tun_if)"
else
    fail "route to 1.1.1.1 does not use '$tun_if': $route"
fi
# Capture before matching: grep -q exits early, and pipefail would then see a
# broken pipe from the command feeding it.
output_rules=$(docker exec "$VPN" iptables -S OUTPUT 2>/dev/null || true)
if grep -qx -- '-P OUTPUT DROP' <<<"$output_rules"; then
    pass "firewall drops outgoing traffic by default"
else
    fail "firewall OUTPUT policy is not DROP"
fi
# The WireGuard endpoint Gluetun connected to last (it logs each connection).
endpoint=$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$VPN")" "$VPN" 2>&1 |
    sed -n 's/.*\[wireguard\] Connecting to \([0-9.]*:[0-9]*\).*/\1/p' | tail -n 1 || true)
# Every OUTPUT rule that accepts traffic must be one of: loopback, established
# connections, the tunnel, the bypassed interface's own subnet, and UDP to the
# WireGuard endpoint on the bypassed interface (which must be there). A rule
# without -o applies to every interface, so it counts too.
rules_verdict=$(python3 -I -c '
import ipaddress, sys
tun, eth, cidr, endpoint = sys.argv[1:]
if not (tun and eth and cidr and ":" in endpoint):
    sys.exit("FAIL missing input: tunnel %r, bypassed %r (%r), endpoint %r" % (tun, eth, cidr, endpoint))
host, port = endpoint.rsplit(":", 1)
iface = ipaddress.ip_interface(cidr)
wireguard = f"-A OUTPUT -d {host}/32 -o {eth} -p udp -m udp --dport {port} -j ACCEPT"
allowed = {
    "-A OUTPUT -o lo -j ACCEPT",
    "-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
    f"-A OUTPUT -o {tun} -j ACCEPT",
    f"-A OUTPUT -s {iface.ip}/32 -d {iface.network} -o {eth} -j ACCEPT",
    wireguard,
}
rules = [line for line in sys.stdin.read().splitlines() if line.startswith("-A OUTPUT ")]
unexpected = [r for r in rules if not r.endswith((" -j DROP", " -j REJECT")) and r not in allowed]
if unexpected:
    print("FAIL unexpected rule(s): " + " | ".join(unexpected))
elif rules.count(wireguard) != 1:
    print("FAIL no rule allowing UDP to the WireGuard endpoint " + endpoint)
else:
    print("OK")' "$tun_if" "$bypass_if" "$bypass_cidr" "$endpoint" <<<"$output_rules" 2>&1 || true)
if [[ "$rules_verdict" == OK ]]; then
    pass "firewall lets out $bypass_if only UDP to the WireGuard endpoint ($endpoint), besides local and established traffic"
else
    fail "firewall OUTPUT rules: ${rules_verdict#FAIL }"
fi
# The kill switch probes have a positive control: the same probe through the
# tunnel must get through, or a failure around it would prove nothing (no
# tool, no permission, the target unreachable).
# Prints curl's exit code for HTTPS to 1.1.1.1 from qBittorrent (on the VPN's
# network) bound to one interface: tcp_probe INTERFACE
tcp_probe() {
    local rc=0
    docker exec "$QBT" curl -s -o /dev/null --max-time 5 --interface "$1" https://1.1.1.1/ \
        >/dev/null 2>&1 || rc=$?
    echo "$rc"
}
# Prints ping's exit code and output for one ICMP echo to 1.1.1.1 from Gluetun
# out one interface: icmp_probe INTERFACE
icmp_probe() {
    local rc=0 output
    output=$(docker exec "$VPN" ping -c 1 -W 3 -I "$1" 1.1.1.1 2>&1) || rc=$?
    echo "$rc $(tr '\n' ' ' <<<"$output")"
}
tun_tcp=1
for _ in 1 2 3; do
    tun_tcp=$(tcp_probe "${tun_if:-none}")
    [[ "$tun_tcp" == 0 ]] && break
    sleep 2
done
bypass_tcp=$(tcp_probe "${bypass_if:-none}")
if [[ "$tun_tcp" != 0 ]]; then
    fail "kill switch (TCP): inconclusive, HTTPS to 1.1.1.1 through '$tun_if' failed too (curl exit $tun_tcp)"
elif [[ "$bypass_tcp" == 7 || "$bypass_tcp" == 28 ]]; then
    pass "kill switch (TCP): HTTPS to 1.1.1.1 forced out $bypass_if is dropped (curl exit $bypass_tcp), through $tun_if it gets through"
else
    fail "kill switch (TCP): HTTPS to 1.1.1.1 forced out '$bypass_if': curl exit $bypass_tcp (0: it got through)"
fi
tun_icmp="1"
for _ in 1 2 3; do
    tun_icmp=$(icmp_probe "${tun_if:-none}")
    [[ "$tun_icmp" == "0 "* ]] && break
    sleep 2
done
bypass_icmp=$(icmp_probe "${bypass_if:-none}")
if [[ "$tun_icmp" != "0 "* ]]; then
    fail "kill switch (ICMP): inconclusive, ping through '$tun_if' failed too: $tun_icmp"
elif [[ "$bypass_icmp" == "1 "* && "$bypass_icmp" == *"Operation not permitted"* ]]; then
    pass "kill switch (ICMP): ping forced out $bypass_if is refused by the firewall, through $tun_if it gets through"
else
    fail "kill switch (ICMP): ping forced out '$bypass_if': exit and output: $bypass_icmp"
fi

echo "== IPv6"
output6_rules=$(docker exec "$VPN" ip6tables -S OUTPUT 2>/dev/null || true)
if grep -qx -- '-P OUTPUT DROP' <<<"$output6_rules"; then
    pass "IPv6 firewall drops outgoing traffic by default"
else
    fail "IPv6 firewall OUTPUT policy is not DROP: $(grep -- '^-P OUTPUT' <<<"$output6_rules" || echo none)"
fi
# Accepting IPv6 OUTPUT rules: loopback, established, the tunnel, and neighbor
# discovery (solicited-node multicast) on the bypassed interface.
rules6_verdict=$(python3 -I -c '
import sys
tun, eth = sys.argv[1:]
allowed = {
    "-A OUTPUT -o lo -j ACCEPT",
    "-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
    f"-A OUTPUT -o {tun} -j ACCEPT",
    f"-A OUTPUT -d ff02::1:ff00:0/104 -o {eth} -j ACCEPT",
}
rules = [line for line in sys.stdin.read().splitlines() if line.startswith("-A OUTPUT ")]
unexpected = [r for r in rules if not r.endswith((" -j DROP", " -j REJECT")) and r not in allowed]
print("FAIL unexpected rule(s): " + " | ".join(unexpected) if unexpected else "OK")' \
    "${tun_if:-none}" "${bypass_if:-none}" <<<"$output6_rules" 2>&1 || true)
if [[ "$rules6_verdict" == OK ]]; then
    pass "IPv6 firewall lets out only the tunnel, loopback, established and neighbor discovery"
else
    fail "IPv6 firewall OUTPUT rules: ${rules6_verdict#FAIL }"
fi
# The host's IPv6 source address, if it has an IPv6 route (a UDP connect sends
# nothing), and its IPv6 egress address as an IPv6-only service sees it.
host_src6=$(python3 -I -c '
import ipaddress, socket
try:
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as s:
        s.connect(("2606:4700:4700::1111", 443))
        address = ipaddress.ip_address(s.getsockname()[0].split("%")[0])
        print(address if address.is_global else "")
except OSError:
    print("")')
host_ip6=""
if [[ -n "$host_src6" ]]; then
    host_ip6=$(retry_ip curl -6 -s --max-time 10 https://api6.ipify.org) || host_ip6=""
fi
ns6_rc=0
ns_ip6=$(docker exec "$QBT" curl -6 -s --max-time 10 https://api6.ipify.org 2>/dev/null) || ns6_rc=$?
# Positive control: the same service over IPv4 from the same namespace.
ns_ip4=$(retry_ip docker exec "$QBT" curl -4 -s --max-time 10 https://api64.ipify.org) || ns_ip4=""
tun_ip6=$(docker exec "$VPN" ip -6 -o addr show dev "${tun_if:-none}" scope global 2>/dev/null || true)
ipv6_verdict=$(python3 -I -c '
import ipaddress, sys
host_src6, host_ip6, rc, ns_ip6, ns_ip4, vpn_ip, tun_ip6 = sys.argv[1:]
if host_src6 and not host_ip6:
    sys.exit(f"FAIL inconclusive: the host has IPv6 ({host_src6}) but api6.ipify.org did not answer it")
if not vpn_ip or ns_ip4 != vpn_ip:
    sys.exit(f"FAIL inconclusive: over IPv4 the namespace got {ns_ip4!r}, the VPN IP is {vpn_ip!r}")
host_net = ipaddress.ip_network(host_ip6 + "/64", strict=False) if host_ip6 else None
host_note = "the host has IPv6 egress" if host_ip6 else "the host has no IPv6"
if rc == "0":
    try:
        address = ipaddress.ip_address(ns_ip6.strip())
    except ValueError:
        sys.exit(f"FAIL unexpected IPv6 answer {ns_ip6!r}")
    if host_net and address in host_net:
        sys.exit(f"FAIL IPv6 LEAK: the namespace left from {address}, in the host network {host_net}")
    if not tun_ip6:
        sys.exit(f"FAIL IPv6 got out from {address} although the tunnel has no IPv6 address")
    print(f"OK IPv6 leaves through the tunnel ({address}; {host_note})")
elif rc in ("7", "28"):
    print(f"OK IPv6 egress fails (curl exit {rc}); over IPv4 the same service sees the VPN IP; {host_note}")
else:
    print(f"FAIL inconclusive: IPv6 request failed with curl exit {rc}")' \
    "$host_src6" "$host_ip6" "$ns6_rc" "$ns_ip6" "$ns_ip4" "$vpn_ip" "$tun_ip6" 2>&1 || true)
if [[ "$ipv6_verdict" == OK* ]]; then
    pass "${ipv6_verdict#OK }"
else
    fail "IPv6 egress: ${ipv6_verdict#FAIL }"
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
# Gluetun's effective DNS settings, from the summary it prints at startup (the
# v3.41 variables are DNS_SERVER, DNS_UPSTREAM_RESOLVER_TYPE and
# DNS_UPSTREAM_RESOLVERS): prints "<forwarder on> <type> <resolvers,...>".
vpn_log=$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$VPN")" "$VPN" 2>&1 || true)
dns_settings=$(python3 -I -c '
import re, sys
lines = sys.stdin.read().splitlines()
def depth(line):
    match = re.search("[├└]── ", line)
    return match.start() if match else -1
def text(line):
    return line[depth(line) + 4:].strip()
starts = [i for i, line in enumerate(lines) if depth(line) >= 0 and text(line) == "DNS settings:"]
if not starts:
    sys.exit("no DNS settings in the startup summary")
section = []
for line in lines[starts[-1] + 1:]:
    if depth(line) <= depth(lines[starts[-1]]):
        break
    section.append(line)
values = {text(l).split(": ")[0]: text(l).split(": ", 1)[1] for l in section if ": " in text(l)}
resolvers = []
for i, line in enumerate(section):
    if text(line) == "Upstream resolvers:":
        for child in section[i + 1:]:
            if depth(child) <= depth(line):
                break
            resolvers.append(text(child).lower())
print(values.get("DNS forwarder server enabled", "?"), values.get("Upstream resolver type", "?"),
      ",".join(resolvers) or "?")' <<<"$vpn_log" 2>&1 || true)
read -r dns_forwarder dns_type dns_resolvers <<<"$dns_settings"
dns_ready=$(python3 -I -c '
import sys
lines = sys.stdin.read().splitlines()
summary = max((i for i, line in enumerate(lines) if "DNS settings:" in line), default=-1)
print("yes" if summary >= 0 and any(line.endswith("[dns] ready") for line in lines[summary:]) else "no")' \
    <<<"$vpn_log")
if [[ "$dns_forwarder" == yes && "$dns_type" == dot && "$dns_resolvers" != "?" && "$dns_ready" == yes ]]; then
    pass "Gluetun's DNS server is on and ready, upstream DNS over TLS to $dns_resolvers"
else
    fail "Gluetun DNS settings: '$dns_settings' (want: yes dot <resolvers>), ready: $dns_ready"
fi
# Autonomous system number and DNS over TLS servers of the upstream providers
# this test knows (from qdm12/dns, the library Gluetun v3.41.3 uses):
# dot_provider NAME prints "<ASN> <server IP>...".
dot_provider() {
    case "$1" in
        cloudflare) echo "13335 1.1.1.1 1.0.0.1" ;;
        *) return 1 ;;
    esac
}
provider_asns=""
dot_servers=""
for provider in ${dns_resolvers//,/ }; do
    if info=$(dot_provider "$provider"); then
        provider_asns="$provider_asns ${info%% *}"
        dot_servers="$dot_servers ${info#* }"
    else
        fail "no DNS over TLS servers known for the upstream provider '$provider'"
    fi
done
# Gluetun holds TLS connections (port 853) to the provider from the tunnel's
# address. A lookup of a new name first makes it use them.
tun_addr=$(docker exec "$VPN" ip -4 -o addr show dev "${tun_if:-none}" 2>/dev/null |
    awk '{ split($4, a, "/"); print a[1]; exit }' || true)
dot_connection=""
for _ in 1 2 3; do
    docker exec "$QBT" getent hosts "$TEST_ID-$RANDOM.example.com" >/dev/null 2>&1 || true
    connections=$(docker exec "$VPN" netstat -tn 2>/dev/null || true)
    for server in $dot_servers; do
        dot_connection=$(awk -v local="$tun_addr" -v remote="$server:853" \
            '$4 ~ "^" local ":" && $5 == remote && $6 == "ESTABLISHED" { print $4 " -> " $5; exit }' \
            <<<"$connections")
        [[ -n "$dot_connection" ]] && break
    done
    [[ -n "$dot_connection" ]] && break
    sleep 2
done
if [[ -n "$tun_addr" && -n "$dot_connection" ]]; then
    pass "Gluetun's DNS over TLS connection to $dns_resolvers goes through the tunnel ($dot_connection)"
else
    fail "no DNS over TLS connection from the tunnel address '$tun_addr' to:$dot_servers"
fi
# Which resolver the outside world sees: Akamai's whoami.ds.akahelp.net
# answers with the resolver that asked ("ns") and the client subnet it passed
# on ("ecs"). Through 127.0.0.1 that must be the DNS over TLS provider, and it
# must differ from what the host's own resolver shows.
vpn_whoami=$(txt_lookup vpn whoami.ds.akahelp.net 2>/dev/null || true)
host_whoami=$(txt_lookup host whoami.ds.akahelp.net 2>/dev/null || true)
vpn_ns=$(awk '$1 == "ns" { print $2; exit }' <<<"$vpn_whoami")
host_ns=$(awk '$1 == "ns" { print $2; exit }' <<<"$host_whoami")
vpn_ns_asn=""
host_ns_asn=""
[[ -n "$vpn_ns" ]] && vpn_ns_asn=$(asn_of vpn "$vpn_ns" 2>/dev/null || true)
[[ -n "$host_ns" ]] && host_ns_asn=$(asn_of host "$host_ns" 2>/dev/null || true)
resolver_verdict=$(python3 -I -c '
import ipaddress, sys
(asns, vpn_whoami, vpn_asn, host_whoami, host_asn, host_ip, vpn_ip, providers) = sys.argv[1:]
def parse(whoami):
    fields = dict(line.split(" ", 1) for line in whoami.splitlines() if " " in line)
    ecs = fields.get("ecs", "")
    return fields.get("ns", ""), "/".join(ecs.split("/")[:2]) if ecs else ""
vpn_ns, vpn_ecs = parse(vpn_whoami)
host_ns, host_ecs = parse(host_whoami)
if not vpn_ns:
    sys.exit(f"FAIL no whoami answer through 127.0.0.1: {vpn_whoami!r}")
if vpn_asn not in asns.split():
    sys.exit(f"FAIL the resolver seen through 127.0.0.1 is {vpn_ns} (AS{vpn_asn}), not {providers} (AS{asns.strip()})")
if vpn_ecs and host_ip and ipaddress.ip_address(host_ip) in ipaddress.ip_network(vpn_ecs, strict=False):
    sys.exit(f"FAIL the resolver passed on the host network {vpn_ecs}")
if not host_ns:
    sys.exit(f"FAIL inconclusive: no whoami answer through the host resolver: {host_whoami!r}")
# The client subnet tells the two paths apart when both pass one on; without
# one, only resolvers of different operators do.
if vpn_ecs and host_ecs:
    if vpn_ecs == host_ecs:
        sys.exit(f"FAIL through 127.0.0.1 the resolver passed on the host resolver client subnet {vpn_ecs}")
elif not vpn_ecs and not host_ecs and (not host_asn or host_asn == vpn_asn):
    sys.exit(f"FAIL inconclusive: no client subnet on either path, host resolver AS {host_asn!r}")
covers = vpn_ecs and vpn_ip and ipaddress.ip_address(vpn_ip) in ipaddress.ip_network(vpn_ecs, strict=False)
subnet = f", client subnet {vpn_ecs}" + (" (the VPN exit network)" if covers else "") if vpn_ecs else ""
print(f"OK {vpn_ns} (AS{vpn_asn}, {providers}){subnet}")' \
    "$provider_asns" "$vpn_whoami" "$vpn_ns_asn" "$host_whoami" "$host_ns_asn" "$host_ip" "$vpn_ip" \
    "$dns_resolvers" 2>&1 || true)
if [[ "$resolver_verdict" == OK* ]]; then
    pass "resolver seen through 127.0.0.1: ${resolver_verdict#OK }, not the host's resolver"
else
    fail "resolver identity: ${resolver_verdict#FAIL }"
fi

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
# qSticky's role allows only GET /v1/portforward and GET /v1/vpn/status: with
# its valid key, other routes must be refused. Read-only routes only (never a
# PUT, or the v0 GET restart routes). Gluetun answers 404 for a route it does
# not have, before any role check, so the 401s are refusals of real routes.
# Prints the HTTP status of a GET with qSticky's key: control_get ROUTE
control_get() {
    docker exec -e GLUETUN_API_KEY "$QBT" sh -c \
        'curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "X-API-Key: $GLUETUN_API_KEY" "http://localhost:8000$1"' \
        sh "$1" 2>/dev/null || true
}
code=$(control_get "/v1/$TEST_ID")
if [[ "$code" == 404 ]]; then
    pass "Gluetun control server answers a route it does not have with 404 (valid API key)"
else
    fail "Gluetun control server answered the unknown route /v1/$TEST_ID with HTTP $code (want 404)"
fi
for route in /v1/publicip/ip /v1/dns/status /v1/vpn/settings /v1/updater/status /v1/version; do
    code=$(control_get "$route")
    if [[ "$code" == 401 ]]; then
        pass "Gluetun control server refuses $route, outside qSticky's role, with its valid API key (401)"
    else
        fail "Gluetun control server answered $route (outside qSticky's role) with its valid API key: HTTP $code"
    fi
done
# Those roles come from the auth file Compose writes into the container from
# .env's GLUETUN_API_KEY (configs: gluetun_auth): the path Gluetun's startup
# summary names must be that file, and Gluetun must have read its one role.
auth_file=$(compose_value vpn config-target:gluetun_auth)
vpn_log=$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$VPN")" "$VPN" 2>&1 || true)
auth_summary=$(sed -n 's/.*Authentication file path: //p' <<<"$vpn_log" | tail -n 1)
if [[ -n "$auth_file" && "$auth_summary" == "$auth_file" ]] &&
    grep -q 'read 1 roles from authentication file' <<<"$vpn_log"; then
    pass "Gluetun read 1 role from $auth_file, the file Compose writes from GLUETUN_API_KEY"
else
    fail "Gluetun's auth file is '$auth_summary', Compose writes '$auth_file'; read 1 role: $(grep -c 'read 1 roles from authentication file' <<<"$vpn_log")"
fi
auth_file_mode=$(docker exec "$VPN" stat -c '%a %u:%g' "${auth_file:-none}" 2>&1 || true)
if [[ "$auth_file_mode" == "400 0:0" ]]; then
    pass "$auth_file is root's and only root may read it (400 0:0)"
else
    fail "Gluetun's auth file '$auth_file': $auth_file_mode (want 400 0:0)"
fi
forwarded=$(docker exec -e GLUETUN_API_KEY "$QBT" sh -c \
    'curl -s --max-time 10 -H "X-API-Key: $GLUETUN_API_KEY" http://localhost:8000/v1/portforward' \
    2>/dev/null | json_get port 2>/dev/null || echo 0)
listen=$(qbt_preferences | json_get listen_port 2>/dev/null || echo "")
if [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)) && [[ "$listen" == "$forwarded" ]]; then
    pass "qBittorrent listens on Gluetun's forwarded port ($forwarded)"
else
    fail "forwarded port '$forwarded', qBittorrent listen port '$listen'"
fi
# Gluetun's effective capabilities (CapEff in /proc, a hex bit mask), as
# names: exactly NET_ADMIN and NET_RAW. Its status files need neither CHOWN nor
# DAC_OVERRIDE with PUID and PGID 0 and the /tmp/gluetun tmpfs.
vpn_caps=$(docker exec "$VPN" cat /proc/1/status 2>/dev/null | python3 -I -c '
import sys
names = """CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER FSETID KILL SETGID SETUID SETPCAP
LINUX_IMMUTABLE NET_BIND_SERVICE NET_BROADCAST NET_ADMIN NET_RAW IPC_LOCK IPC_OWNER
SYS_MODULE SYS_RAWIO SYS_CHROOT SYS_PTRACE SYS_PACCT SYS_ADMIN SYS_BOOT SYS_NICE
SYS_RESOURCE SYS_TIME SYS_TTY_CONFIG MKNOD LEASE AUDIT_WRITE AUDIT_CONTROL SETFCAP
MAC_OVERRIDE MAC_ADMIN SYSLOG WAKE_ALARM BLOCK_SUSPEND AUDIT_READ PERFMON BPF
CHECKPOINT_RESTORE""".split()
masks = [line.split()[1] for line in sys.stdin if line.startswith("CapEff:")]
if not masks:
    sys.exit("?")
mask = int(masks[0], 16)
print(" ".join(sorted(names[i] if i < len(names) else f"bit{i}" for i in range(64) if mask >> i & 1)) or "none")' 2>&1 || true)
if [[ "$vpn_caps" == "NET_ADMIN NET_RAW" ]]; then
    pass "Gluetun's effective capabilities are exactly NET_ADMIN and NET_RAW"
else
    fail "Gluetun's effective capabilities: $vpn_caps (want NET_ADMIN NET_RAW)"
fi
# Gluetun writes the forwarded port to its status file too, as root's (PUID
# and PGID 0), and logs any failure to create, chown or rewrite it.
port_file=$(compose_value vpn env:VPN_PORT_FORWARDING_STATUS_FILE)
port_file=${port_file:-/tmp/gluetun/forwarded_port}
port_file_content=$(docker exec "$VPN" cat "$port_file" 2>&1 || true)
port_file_owner=$(docker exec "$VPN" stat -c '%u:%g' "$port_file" 2>&1 || true)
if [[ "$forwarded" =~ ^[0-9]+$ ]] && ((forwarded > 0)) &&
    [[ "$port_file_content" == "$forwarded" && "$port_file_owner" == 0:0 ]]; then
    pass "$port_file holds the forwarded port ($forwarded) and is owned by 0:0"
else
    fail "$port_file holds '$port_file_content', owner '$port_file_owner' (want '$forwarded', 0:0)"
fi
# A file it may not open fails with "permission denied" (EACCES), a chown or
# chmod it may not make with "operation not permitted" (EPERM) after the
# call's name. Not every EPERM: while the tunnel is down, the kill switch
# refuses Gluetun's own packets out the other interface with it too.
vpn_log=$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$VPN")" "$VPN" 2>&1 || true)
file_errors=$(grep -iE 'chown|chmod|permission denied' <<<"$vpn_log" || true)
if [[ -n "$vpn_log" && -z "$file_errors" ]]; then
    pass "Gluetun logged no chown, chmod or permission error since it started"
else
    fail "Gluetun's log since it started: ${file_errors:-empty}"
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
# Host-header validation, the defense against DNS rebinding (a web page that
# re-points its own name to this computer): qBittorrent must refuse any Host
# name but the ones its clients use. Those are the browser on this computer
# (localhost or 127.0.0.1) and, inside the VPN's network, qSticky and Firefox's
# Torrent Control (localhost). Prints the HTTP status of GET app/version, from
# this computer or from inside the VPN's network: qbt_status host|namespace URL [HOST]
qbt_status() {
    local headers=()
    [[ -n "${3:-}" ]] && headers=(-H "Host: $3")
    if [[ "$1" == host ]]; then
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${headers[@]+"${headers[@]}"} \
            "$2/api/v2/app/version" 2>/dev/null || true
    else
        docker exec "$QBT" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            ${headers[@]+"${headers[@]}"} "$2/api/v2/app/version" 2>/dev/null || true
    fi
}
for case in "host $QBT_URL" "host http://127.0.0.1:9080" "namespace http://localhost:9080"; do
    read -r where url <<<"$case"
    code=$(qbt_status "$where" "$url")
    if [[ "$code" == 200 ]]; then
        pass "WebUI accepts its own name: $url from the $where (200)"
    else
        fail "WebUI refused $url from the $where: HTTP $code (want 200)"
    fi
done
rebind_name="rebind-$TEST_ID.example"
for case in "host $rebind_name:9080" "host $rebind_name" "namespace $rebind_name:9080"; do
    read -r where host_header <<<"$case"
    url=$QBT_URL
    [[ "$where" == namespace ]] && url=http://localhost:9080
    code=$(qbt_status "$where" "$url" "$host_header")
    # qBittorrent logs each refused Host header: proof the 401 is that check.
    logged=$(curl -s --max-time 10 "$QBT_URL/api/v2/log/main?normal=false&info=false&critical=false" |
        SUFFIX="Received Host header: '$host_header'" python3 -I -c '
import json, os, sys
print("yes" if any(m["message"].startswith("WebUI: Invalid Host header. Request source IP: ")
                   and m["message"].endswith(os.environ["SUFFIX"])
                   for m in json.load(sys.stdin)) else "no")' 2>/dev/null || echo no)
    if [[ "$code" == 401 && "$logged" == yes ]]; then
        pass "WebUI refuses Host: $host_header from the $where (401, logged as an invalid Host header)"
    else
        fail "WebUI answered Host: $host_header from the $where with HTTP $code (want 401); logged as invalid: $logged"
    fi
done
settings=$(qbt_preferences | python3 -I "$STACK_DIR/qbt_settings.py" 2>&1 || true)
if [[ -z "$settings" ]]; then
    pass "download paths, /watch folder, UPnP off and the WebUI host names as the init script sets them"
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
# The web UI serves the patched noVNC files the service mounts (config/cursors/README.md),
# byte for byte (neither has a placeholder nginx substitutes), with no-cache.
for novnc_file in core/util/cursor.js app/ui.js; do
    served="$WORK/served-${novnc_file##*/}"
    novnc_headers=$(curl -s -D - -o "$served" --max-time 10 "$FIREFOX_URL/$novnc_file" || true)
    if cmp -s "$served" "$REPO/config/novnc/${novnc_file##*/}" &&
        grep -qi '^cache-control: no-cache' <<<"$novnc_headers"; then
        pass "web UI serves config/novnc/${novnc_file##*/} as /$novnc_file, with no-cache"
    else
        fail "web UI's /$novnc_file is not config/novnc/${novnc_file##*/} with no-cache"
    fi
done
# index.html loads ui.js with the content hash of /opt/noVNC, which changes when a mounted
# file does, so a browser that has an older ui.js cached fetches the new one.
web_version=$(curl -s --max-time 10 "$FIREFOX_URL/webdata.json" |
    python3 -I -c 'import json, sys; print(json.load(sys.stdin)["webUniqueVersion"])' || true)
if [[ -n "$web_version" ]] &&
    curl -s --max-time 10 "$FIREFOX_URL/" | grep -qF "./app/ui.js?v=$web_version\""; then
    pass "index.html loads ui.js with the web UI's content hash ($web_version)"
else
    fail "index.html does not load ./app/ui.js?v=<webUniqueVersion> ('$web_version')"
fi
# Permanent private browsing follows FIREFOX_PRIVATE_BROWSING in .env, as Compose
# resolves it (config.json above): the running container got that entry, its init
# script accepted it, and prefs.js has the pref true when on, and no true line when
# off (Firefox leaves out a value equal to its default, false).
private_entry=$(compose_value firefox env:FF_PREF_PRIVATE_BROWSING)
running_entry=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$FIREFOX" 2>/dev/null |
    sed -n 's/^FF_PREF_PRIVATE_BROWSING=//p' || true)
private_line=$(docker exec "$FIREFOX" grep -F 'user_pref("browser.privatebrowsing.autostart",' \
    /config/profile/prefs.js 2>/dev/null || true)
firefox_log=$(docker logs --since "$(docker inspect -f '{{.State.StartedAt}}' "$FIREFOX")" \
    "$FIREFOX" 2>&1 || true)
case "$private_entry" in
    browser.privatebrowsing.autostart=true)
        private_mode=on
        want_lines=('user_pref("browser.privatebrowsing.autostart", true);')
        ;;
    browser.privatebrowsing.autostart=false)
        private_mode=off
        want_lines=('' 'user_pref("browser.privatebrowsing.autostart", false);')
        ;;
    *)
        private_mode=""
        want_lines=()
        ;;
esac
private_line_ok=no
# (The ${...+...} form expands an empty array without an error in bash 3.2 too.)
for want in ${want_lines[@]+"${want_lines[@]}"}; do
    [[ "$private_line" == "$want" ]] && private_line_ok=yes
done
if [[ -n "$private_mode" && "$running_entry" == "$private_entry" && "$private_line_ok" == yes ]] &&
    grep -qF "54-firefox-private-browsing.sh: permanent private browsing is $private_mode" \
        <<<"$firefox_log"; then
    pass "private browsing is $private_mode, as FIREFOX_PRIVATE_BROWSING in .env sets ($private_entry)"
else
    fail "private browsing: Compose resolves '$private_entry', the container has '$running_entry', prefs.js has '${private_line:-no line}'; init log: $(grep -F 54-firefox-private-browsing.sh <<<"$firefox_log" | tail -n 1)"
fi
windows=$(docker exec -u "$FIREFOX_UID" -e DISPLAY=:0 "$FIREFOX" \
    xdotool search --onlyvisible --classname Navigator 2>/dev/null | wc -l | tr -d ' ')
if [[ "$windows" == 1 ]]; then
    pass "Firefox shows exactly one window"
else
    fail "Firefox shows $windows windows"
fi

echo "== Docker socket proxy"
# Only the proxy may mount the Docker socket (read-only: that stops writes to
# the socket file, not API calls through it); Autoheal must use the proxy.
socket_mounts=""
for container in "$VPN" "$QBT" "$QSTICKY" "$FIREFOX" "$AUTOHEAL" "${PROXY:-autoheal-proxy}"; do
    mounts=$(docker inspect -f '{{range .Mounts}}{{.Destination}} rw={{.RW}}{{println}}{{end}}' \
        "$container" 2>/dev/null || true)
    while read -r destination rw; do
        if [[ "$destination" == /var/run/docker.sock ]]; then
            socket_mounts="$socket_mounts $container($rw)"
        fi
    done <<<"$mounts"
done
if [[ -n "$PROXY" && "$socket_mounts" == " $PROXY(rw=false)" ]]; then
    pass "only $PROXY mounts the Docker socket, read-only"
else
    fail "containers mounting the Docker socket:${socket_mounts:- none} (want only ${PROXY:-autoheal-proxy}, read-only)"
fi
autoheal_sock=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$AUTOHEAL" 2>/dev/null |
    sed -n 's/^DOCKER_SOCK=//p' || true)
if [[ -n "$PROXY" && "$autoheal_sock" == "tcp://"* ]]; then
    pass "Autoheal uses the Docker API at $autoheal_sock"
else
    fail "Autoheal's DOCKER_SOCK is '$autoheal_sock', not the proxy's tcp:// address"
fi
proxy_url="http://${autoheal_sock#tcp://}"
[[ "$autoheal_sock" == "tcp://"* ]] || proxy_url="http://autoheal-proxy:2375"
# Sends a request through the proxy from inside Autoheal's container, as
# Autoheal does: proxy_request METHOD PATH [JSON BODY]. Prints the HTTP status,
# then "proxy-denied" when the answer is HAProxy's own 403 page, not Docker's.
proxy_request() {
    local args=(-s --max-time 20 -X "$1" -w '\n%{http_code}') response
    [[ -n "${3:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$3")
    response=$(docker exec "$AUTOHEAL" curl "${args[@]}" "$proxy_url$2" 2>/dev/null) || true
    printf '%s' "${response##*$'\n'}"
    [[ "$response" == *"Request forbidden by administrative rules"* ]] && printf ' proxy-denied'
    echo
}
# A target that autoheal ignores (no label) and that the restart may stop at once.
docker run -d --name "$TEST_ID-proxy-target" --network none "$PLAIN_IMAGE" sleep 600 >/dev/null
target_id=$(docker inspect -f '{{.Id}}' "$TEST_ID-proxy-target")
target_start=$(docker inspect -f '{{.State.StartedAt}}' "$TEST_ID-proxy-target")
result=$(proxy_request GET /containers/json)
if [[ "$result" == 200 ]]; then
    pass "the proxy allows GET /containers/json (200)"
else
    fail "GET /containers/json through the proxy: $result (want 200)"
fi
result=$(proxy_request POST "/containers/create?name=$TEST_ID-created" \
    "{\"Image\": \"$PLAIN_IMAGE\", \"Cmd\": [\"true\"]}")
created=no
docker inspect "$TEST_ID-created" >/dev/null 2>&1 && created=yes
if [[ "$result" == "403 proxy-denied" && "$created" == no ]]; then
    pass "the proxy refuses POST /containers/create (403; no container created)"
else
    fail "POST /containers/create through the proxy: $result (want 403 proxy-denied); created: $created"
fi
result=$(proxy_request GET "/containers/$target_id/json")
if [[ "$result" == "403 proxy-denied" ]]; then
    pass "the proxy refuses GET /containers/<id>/json (403: no container's environment)"
else
    fail "GET /containers/<id>/json through the proxy: $result (want 403 proxy-denied)"
fi
result=$(proxy_request POST "/containers/$target_id/exec" '{"Cmd": ["true"]}')
if [[ "$result" == "403 proxy-denied" ]]; then
    pass "the proxy refuses POST /containers/<id>/exec (403)"
else
    fail "POST /containers/<id>/exec through the proxy: $result (want 403 proxy-denied)"
fi
result=$(proxy_request POST "/containers/$target_id/stop?t=1")
if [[ "$result" == "403 proxy-denied" &&
    "$(docker inspect -f '{{.State.Running}}' "$TEST_ID-proxy-target")" == true ]]; then
    pass "the proxy refuses POST /containers/<id>/stop (403; the container still runs)"
else
    fail "POST /containers/<id>/stop through the proxy: $result (want 403 proxy-denied); running: $(docker inspect -f '{{.State.Running}}' "$TEST_ID-proxy-target")"
fi
result=$(proxy_request POST "/containers/$target_id/restart?t=1")
if [[ "$result" == 204 &&
    "$(docker inspect -f '{{.State.StartedAt}}' "$TEST_ID-proxy-target")" != "$target_start" ]]; then
    pass "the proxy allows POST /containers/<id>/restart (204; the container restarted)"
else
    fail "POST /containers/<id>/restart through the proxy: $result (want 204), or the container did not restart"
fi
docker rm -f "$TEST_ID-proxy-target" >/dev/null 2>&1 || true

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
# The labeled container ignores SIGTERM (sleep is its PID 1), so its restart
# takes the whole stop timeout. Autoheal's curl must wait for the answer
# (CURL_TIMEOUT): when it gave up first, Autoheal logged "Restarting container
# ... failed" although the restart went through. The proxy logs each request
# when it ends, with Docker's status, or with 400 and termination state CH--
# when the client closed the connection first.
labeled_id=$(docker inspect -f '{{.Id}}' "$TEST_ID-labeled")
restart_line=""
wait_until=$((SECONDS + 30))
while ((SECONDS < wait_until)); do
    proxy_log=$(docker logs --since 15m "${PROXY:-autoheal-proxy}" 2>&1) || proxy_log=""
    restart_line=$(grep -m 1 "POST /containers/$labeled_id/restart" <<<"$proxy_log") || true
    [[ -n "$restart_line" ]] && break
    sleep 2
done
if [[ "$restart_line" =~ \ 204\ [0-9]+\ -\ -\ ----\  ]]; then
    pass "Autoheal's restart call waited for the restart to finish (the proxy logged 204)"
else
    fail "Autoheal's restart call (want 204 and ---- in the proxy's log): ${restart_line:-no log line}"
fi
autoheal_log=$(docker logs --since 15m "$AUTOHEAL" 2>&1) || autoheal_log=""
failed_line=$(grep -m 1 "Restarting container ${labeled_id:0:12} failed" <<<"$autoheal_log") || true
if [[ -n "$restart_line" && -z "$failed_line" ]]; then
    pass "Autoheal did not log the restart as failed"
else
    fail "Autoheal logged: ${failed_line:-no restart call in the proxy log}"
fi

if ((failures > 0)); then
    echo "$failures of $checks check(s) failed"
    exit 1
fi
echo "all $checks checks passed"
