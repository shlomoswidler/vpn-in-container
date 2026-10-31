#!/usr/bin/env bash
# Fresh-install test of the qBittorrent init script, as on a new clone.
#
# Starts the pinned qBittorrent image in a throwaway container with no network
# (--network none), an empty /config (an anonymous volume: a bind mount on
# OrbStack shows every file as root's inside the container, which would hide
# the owner check), empty /watch and /downloads folders, and
# config/qbittorrent-init.d mounted as in docker-compose.yml. Then checks,
# through qBittorrent's own API (from inside the container, over loopback):
#   - the init script's settings are live, /watch included, and /watch saves
#     to /downloads/
#   - the watched_folders.json the script created belongs to the user
#     qBittorrent runs as (PUID/PGID), so qBittorrent can rewrite it
#   - a .torrent dropped into /watch is added, with save path /downloads/, and
#     qBittorrent removes the file from /watch
#   - after a restart the script leaves the file alone and /watch is still
#     watched
#   - docker stop lets qBittorrent exit cleanly, before the stop timeout
#
# The container gets the service's security options and capabilities
# (tests/run_args.py), so this also checks that the image works as hardened
# as the service, on a volume with Linux file ownership.
#
# Usage: tests/qbittorrent/fresh-install.sh [IMAGE]
#        (default: the qbittorrent service's image in docker-compose.yml;
#         needs docker and python3 on the host)

set -euo pipefail

QBT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$QBT_DIR/../.." && pwd)
STACK_DIR="$REPO/tests/stack"
WORK=$(mktemp -d)
CONTAINER="qbt-fresh-install-test-$$"
WEBUI_PORT=9080
TIMEOUT=120

cleanup() {
    # -v: also the anonymous /config volume.
    docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
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

docker compose -f "$REPO/docker-compose.yml" config --format json >"$WORK/compose.json"
HARDENING=()
while IFS= read -r arg; do
    HARDENING+=("$arg")
done < <(python3 -I "$REPO/tests/run_args.py" qbittorrent <"$WORK/compose.json")
IMAGE=${1:-$(service_value image)}
PUID=$(service_value PUID)
PGID=$(service_value PGID)
echo "image: $IMAGE"
echo "hardening: ${HARDENING[*]:-none}"

failures=0
pass() { printf 'ok    %s\n' "$*"; }
fail() {
    printf 'FAIL  %s\n' "$*"
    failures=$((failures + 1))
}

# Calls the qBittorrent API inside the container: api PATH [curl args...]
api() {
    local path=$1
    shift
    docker exec "$CONTAINER" curl -s --max-time 10 "$@" "http://localhost:$WEBUI_PORT/api/v2/$path"
}

# Waits until the WebUI answers; prints the version.
wait_webui() {
    local deadline=$((SECONDS + TIMEOUT)) version=""
    while ((SECONDS < deadline)); do
        version=$(api app/version 2>/dev/null || true)
        if [[ "$version" == v* ]]; then
            echo "$version"
            return 0
        fi
        sleep 2
    done
    return 1
}

# Prints the problems with the watched folders in qBittorrent's preferences
# (JSON on stdin), or nothing: /watch must be watched and save to /downloads/.
# qBittorrent reports each folder's save path as a string (without a trailing
# slash), 0 for the folder itself or 1 for the default save path.
scan_dir_problems() {
    python3 -I -c '
import json, sys
dirs = json.load(sys.stdin).get("scan_dirs")
target = dirs.get("/watch") if isinstance(dirs, dict) else None
if not isinstance(target, str) or target.rstrip("/") != "/downloads":
    print(f"scan_dirs={dirs!r}")'
}

WATCH_FILE=/config/qBittorrent/watched_folders.json
mkdir -p "$WORK/watch" "$WORK/downloads"
docker run -d --name "$CONTAINER" --network none ${HARDENING[@]+"${HARDENING[@]}"} \
    -e "PUID=$PUID" -e "PGID=$PGID" -e "WEBUI_PORT=$WEBUI_PORT" \
    --mount type=volume,dst=/config \
    -v "$REPO/config/qbittorrent-init.d:/custom-cont-init.d:ro" \
    -v "$WORK/watch:/watch" -v "$WORK/downloads:/downloads" \
    "$IMAGE" >/dev/null

if ! version=$(wait_webui); then
    fail "WebUI did not start within ${TIMEOUT}s"
    docker logs "$CONTAINER" 2>&1 | tail -30
    exit 1
fi
echo "running $version"

log=$(docker logs "$CONTAINER" 2>&1)
if [[ "$log" == *"[qbt-init] Adding /watch to the watched folders"* &&
    "$log" == *"[qbt-init] Configuration complete"* ]]; then
    pass "the init script added /watch on a fresh /config"
else
    fail "the init script did not add /watch: $(grep -F '[qbt-init]' <<<"$log" | paste -sd '|' -)"
fi

owner=$(docker exec "$CONTAINER" stat -c %u:%g "$WATCH_FILE" 2>&1 || true)
if [[ "$owner" == "$PUID:$PGID" ]]; then
    pass "watched_folders.json belongs to the user qBittorrent runs as ($owner)"
else
    fail "watched_folders.json owner is '$owner', not $PUID:$PGID"
fi

prefs=$(api app/preferences)
settings=$(python3 -I "$STACK_DIR/qbt_settings.py" <<<"$prefs" 2>&1 || true)
scan=$(scan_dir_problems <<<"$prefs" 2>&1 || true)
if [[ -z "$settings" && -z "$scan" ]]; then
    pass "the init script's settings are live, and /watch saves to /downloads/"
else
    fail "settings on a fresh install: $settings $scan"
fi

hash=$(python3 -I "$STACK_DIR/torrent_file.py" "$WORK/test.torrent" "$CONTAINER")
cp "$WORK/test.torrent" "$WORK/watch/$CONTAINER.torrent"
save_path=""
deadline=$((SECONDS + 60))
while ((SECONDS < deadline)); do
    save_path=$(api "torrents/info?hashes=$hash" | python3 -I -c '
import json, sys
torrents = json.load(sys.stdin)
print(torrents[0]["save_path"] if torrents else "")' 2>/dev/null || true)
    [[ -n "$save_path" ]] && break
    sleep 2
done
# qBittorrent deletes a watched .torrent once it has handed it to the session.
if [[ "${save_path%/}" == /downloads && ! -e "$WORK/watch/$CONTAINER.torrent" ]]; then
    pass "a .torrent dropped into /watch was added, saving to $save_path, and removed from /watch"
elif [[ "${save_path%/}" == /downloads ]]; then
    fail "the .torrent dropped into /watch was added but is still in /watch"
elif [[ -n "$save_path" ]]; then
    fail "the .torrent dropped into /watch was added with save path $save_path, not /downloads/"
else
    fail "a .torrent dropped into /watch was not added within 60s"
fi

before=$(docker exec "$CONTAINER" cat "$WATCH_FILE")
docker restart "$CONTAINER" >/dev/null
if wait_webui >/dev/null; then
    restart_log=$(docker logs --since 1m "$CONTAINER" 2>&1)
    scan=$(api app/preferences | scan_dir_problems 2>&1 || true)
    if [[ "$restart_log" == *"[qbt-init] /watch is already a watched folder"* &&
        "$(docker exec "$CONTAINER" cat "$WATCH_FILE")" == "$before" && -z "$scan" ]]; then
        pass "after a restart the file is unchanged and /watch is still watched"
    else
        fail "after a restart: $(grep -F '[qbt-init]' <<<"$restart_log" | paste -sd '|' -) $scan"
    fi
else
    fail "WebUI did not come back within ${TIMEOUT}s after a restart"
fi

# s6 (PID 1, root) passes Docker's SIGTERM on to qBittorrent, which runs as
# PUID: signaling another user's process needs the KILL capability. Without it
# qBittorrent never hears of the stop, and Docker kills it at the timeout,
# before it saves its resume data.
# qBittorrent prints "Exiting cleanly" once per clean exit (the restart above
# printed one too).
STOP_TIMEOUT=30
clean_exits() { docker logs "$CONTAINER" 2>&1 | grep -cxF 'Exiting cleanly' || true; }
before=$(clean_exits)
started=$SECONDS
docker stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null
took=$((SECONDS - started))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
after=$(clean_exits)
if [[ "$exit_code" == 0 ]] && ((took < STOP_TIMEOUT && after == before + 1)); then
    pass "docker stop: qBittorrent exited cleanly in ${took}s"
else
    fail "docker stop: exit code $exit_code after ${took}s (timeout ${STOP_TIMEOUT}s), $((after - before)) new 'Exiting cleanly' line(s)"
fi

if ((failures > 0)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all fresh-install checks passed"
