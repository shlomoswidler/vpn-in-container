#!/usr/bin/env bash
# Real BitTorrent download test for the qBittorrent image, with no internet.
#
# Starts two throwaway containers from the image on an internal Docker network
# (no outside access): a seeder with random multi-file content, and a leecher
# that downloads it from the seeder only (private torrent, no trackers, DHT,
# PeX or LSD; the peer is added by address). Then checks every downloaded
# file's SHA-256 against the original and runs qBittorrent's own recheck:
# with the torrent stopped, one changed byte must make the recheck report that
# piece missing, and restoring it must make the recheck report 100% again.
# Written for the libtorrent 2.1 reports of downloads that never finish or
# report 100% early.
#
# Usage: tests/qbittorrent/download.sh [IMAGE]
#        (default: the qbittorrent service's image in docker-compose.yml;
#         needs docker and python3 on the host)

set -euo pipefail

QBT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$QBT_DIR/../.." && pwd)
WORK=$(mktemp -d)
NET="qbt-download-test-$$"
SEEDER="$NET-seeder"
LEECHER="$NET-leecher"
WEBUI_PORT=8080
PEER_PORT=6881
TIMEOUT=240

cleanup() {
    docker rm -f -v "$SEEDER" "$LEECHER" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

service_value() {
    docker compose -f "$REPO/docker-compose.yml" config --format json | python3 -I -c '
import json, sys
svc = json.load(sys.stdin)["services"]["qbittorrent"]
key = sys.argv[1]
print(svc["image"] if key == "image" else svc.get("environment", {}).get(key, ""))' "$1"
}

IMAGE=${1:-$(service_value image)}
PUID=$(service_value PUID)
PGID=$(service_value PGID)
echo "image: $IMAGE"

# A qBittorrent config with the WebUI open to localhost (for the API calls
# below) and every peer-discovery method off.
write_config() {
    mkdir -p "$1/qBittorrent"
    cat >"$1/qBittorrent/qBittorrent.conf" <<EOF
[BitTorrent]
Session\\AddTorrentStopped=false
Session\\DHTEnabled=false
Session\\LSDEnabled=false
Session\\PeXEnabled=false
Session\\Port=$PEER_PORT
Session\\TempPathEnabled=false

[LegalNotice]
Accepted=true

[Network]
PortForwardingEnabled=false

[Preferences]
WebUI\\LocalHostAuth=false
WebUI\\Port=$WEBUI_PORT
EOF
}

# Calls the qBittorrent API inside CONTAINER: api CONTAINER PATH [curl args...]
api() {
    local container=$1 path=$2
    shift 2
    docker exec "$container" curl -s --max-time 10 "$@" "http://localhost:$WEBUI_PORT/api/v2/$path"
}

# Prints "progress state" for the test torrent in CONTAINER.
torrent_status() {
    api "$1" "torrents/info?hashes=$HASH" | python3 -I -c '
import json, sys
torrents = json.load(sys.stdin)
print(str(torrents[0]["progress"]) + " " + torrents[0]["state"] if torrents else "missing -")' 2>/dev/null ||
        echo "error -"
}

# Waits until the test torrent in CONTAINER is complete and not checking.
wait_complete() {
    local container=$1 deadline=$((SECONDS + TIMEOUT)) status
    while ((SECONDS < deadline)); do
        status=$(torrent_status "$container")
        case "$status" in
            "1 uploading" | "1 stalledUP" | "1 queuedUP" | "1 stoppedUP" | "1 forcedUP")
                return 0
                ;;
        esac
        sleep 2
    done
    echo "      $container still '$status' after ${TIMEOUT}s" >&2
    return 1
}

# Prints the test torrent's piece states in CONTAINER as one digit per piece
# (0 = missing, 1 = downloading, 2 = verified).
piece_states() {
    api "$1" "torrents/pieceStates?hash=$HASH" | python3 -I -c '
import json, sys
print("".join(str(state) for state in json.load(sys.stdin)))' 2>/dev/null ||
        echo "error"
}

# Waits until the test torrent in CONTAINER has state STATE and piece states
# PIECES (see piece_states).
wait_pieces() {
    local container=$1 state=$2 pieces=$3 deadline=$((SECONDS + TIMEOUT)) status actual
    while ((SECONDS < deadline)); do
        status=$(torrent_status "$container")
        actual=$(piece_states "$container")
        if [[ "${status#* }" == "$state" && "$actual" == "$pieces" ]]; then
            return 0
        fi
        sleep 1
    done
    echo "      $container: expected $state, pieces $pieces" >&2
    echo "      got '$status', pieces $actual after ${TIMEOUT}s" >&2
    return 1
}

# Writes the byte with octal value OCTAL at the start of FILE (a path under
# /downloads) inside CONTAINER, without truncating the file.
write_first_byte() {
    docker exec "$1" sh -c 'printf "\\$1" | dd of="$2" bs=1 count=1 conv=notrunc 2>/dev/null' \
        sh "$2" "$3"
}

failures=0
pass() { printf 'ok    %s\n' "$*"; }
fail() {
    printf 'FAIL  %s\n' "$*"
    failures=$((failures + 1))
}

mkdir -p "$WORK/content" "$WORK/leecher-downloads"
python3 -I "$QBT_DIR/make_torrent.py" "$WORK/content" "$WORK/test.torrent" >"$WORK/manifest"
HASH=$(head -n 1 "$WORK/manifest")
write_config "$WORK/seeder-config"
write_config "$WORK/leecher-config"

docker network create --internal "$NET" >/dev/null
for role in seeder leecher; do
    if [[ "$role" == seeder ]]; then
        container=$SEEDER
        downloads="$WORK/content"
    else
        container=$LEECHER
        downloads="$WORK/leecher-downloads"
    fi
    docker run -d --name "$container" --network "$NET" \
        -e "PUID=$PUID" -e "PGID=$PGID" -e "WEBUI_PORT=$WEBUI_PORT" \
        -e "TORRENTING_PORT=$PEER_PORT" \
        -v "$WORK/$role-config:/config" -v "$downloads:/downloads" \
        "$IMAGE" >/dev/null
done

for container in "$SEEDER" "$LEECHER"; do
    version=""
    for _ in $(seq 1 60); do
        version=$(api "$container" app/version 2>/dev/null || true)
        [[ "$version" == v* ]] && break
        sleep 2
    done
    if [[ "$version" != v* ]]; then
        fail "$container WebUI did not start"
        docker logs "$container" 2>&1 | tail -20
        exit 1
    fi
done
build=$(api "$SEEDER" app/buildInfo | python3 -I -c '
import json, sys
b = json.load(sys.stdin)
print("libtorrent " + str(b.get("libtorrent")) + ", Qt " + str(b.get("qt")))')
echo "running $version ($build)"

for container in "$SEEDER" "$LEECHER"; do
    docker cp "$WORK/test.torrent" "$container:/tmp/test.torrent"
    api "$container" torrents/add -F torrents=@/tmp/test.torrent -F savepath=/downloads >/dev/null
done
if wait_complete "$SEEDER"; then
    pass "seeder verified the content (100%)"
else
    fail "seeder did not reach 100% on its own content"
fi

seeder_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$SEEDER")
api "$LEECHER" torrents/addPeers --data "hashes=$HASH&peers=$seeder_ip:$PEER_PORT" >/dev/null
started=$SECONDS
if wait_complete "$LEECHER"; then
    pass "leecher downloaded the torrent from the seeder in $((SECONDS - started))s"
else
    fail "leecher did not finish downloading"
fi

mismatches=0
while read -r digest relative; do
    actual=$(shasum -a 256 "$WORK/leecher-downloads/qbt-download-test/$relative" 2>/dev/null | cut -d ' ' -f 1)
    if [[ "$actual" != "$digest" ]]; then
        echo "      $relative: expected $digest, got ${actual:-missing}"
        mismatches=$((mismatches + 1))
    fi
done < <(tail -n +2 "$WORK/manifest")
if ((mismatches == 0)); then
    pass "every downloaded file matches the original (SHA-256)"
else
    fail "$mismatches downloaded file(s) differ from the original"
fi

# qBittorrent's own recheck. The torrent is stopped first, so nothing is
# downloaded again and only a recheck can change its pieces. Changing the
# first byte of the first file must make a recheck report piece 0 missing;
# restoring the byte must make a second recheck report every piece again. A
# recheck that never runs, or that does not read the data, fails one of them.
api "$LEECHER" torrents/stop --data "hashes=$HASH" >/dev/null
read -r _ first_relative < <(sed -n 2p "$WORK/manifest")
first_file="/downloads/qbt-download-test/$first_relative"
original=$(head -c 1 "$WORK/content/qbt-download-test/$first_relative" | od -An -tu1 | tr -d ' ')
all_pieces=$(piece_states "$LEECHER")
if [[ "$all_pieces" =~ ^2+$ ]] && wait_pieces "$LEECHER" stoppedUP "$all_pieces"; then
    missing_first="0${all_pieces:1}"
    write_first_byte "$LEECHER" "$(printf '%03o' $((original ^ 255)))" "$first_file"
    api "$LEECHER" torrents/recheck --data "hashes=$HASH" >/dev/null
    if wait_pieces "$LEECHER" stoppedDL "$missing_first"; then
        pass "recheck after changing one byte: piece 0 of ${#all_pieces} missing"
    else
        fail "recheck did not find the changed piece"
    fi
    write_first_byte "$LEECHER" "$(printf '%03o' "$original")" "$first_file"
    api "$LEECHER" torrents/recheck --data "hashes=$HASH" >/dev/null
    if wait_pieces "$LEECHER" stoppedUP "$all_pieces" && wait_complete "$LEECHER"; then
        pass "qBittorrent's own recheck of the restored download: 100%"
    else
        fail "qBittorrent's recheck of the restored download did not reach 100%"
    fi
else
    fail "the stopped download does not have every piece: '$all_pieces'"
fi

if ((failures > 0)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all download checks passed"
