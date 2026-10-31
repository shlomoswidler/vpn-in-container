#!/bin/bash
# Configure qBittorrent settings on container start
# Ensures proper configuration persists across restarts

# QBT_CONF_FILE overrides the path for tests (tests/test_qbittorrent_init.py).
CONF_FILE="${QBT_CONF_FILE:-/config/qBittorrent/qBittorrent.conf}"
# QBT_CONF_WAIT overrides how many seconds to wait for the config file, for tests.
CONF_WAIT="${QBT_CONF_WAIT:-30}"

if [[ ! "$CONF_WAIT" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "[qbt-init] QBT_CONF_WAIT must be a whole number of seconds, not '$CONF_WAIT'" >&2
    exit 1
fi

echo "[qbt-init] Starting qBittorrent configuration..."

# Wait for config file to exist (created on first run)
for ((i = 0; i < CONF_WAIT; i++)); do
    if [[ -f "$CONF_FILE" ]]; then
        break
    fi
    sleep 1
done

if [[ ! -f "$CONF_FILE" ]]; then
    echo "[qbt-init] Config file not found, skipping"
    exit 0
fi

# Sets KEY=VALUE inside [SECTION], replacing the key if the section has it,
# adding it at the end of the section otherwise, and adding the section if the
# file lacks it. Keys are matched literally (they contain backslashes), so they
# are passed to awk through the environment rather than -v, which would
# interpret the backslashes as escapes.
set_config() {
    local section="$1" key="$2" value="$3" tmp
    tmp=$(mktemp)
    SECTION="$section" KEY="$key" VALUE="$value" awk '
        BEGIN { section = ENVIRON["SECTION"]; key = ENVIRON["KEY"]; line = key "=" ENVIRON["VALUE"] }
        /^\[.*\]$/ {
            if (in_section && !done) { print line; done = 1 }
            in_section = ($0 == "[" section "]")
            seen = seen || in_section
        }
        in_section && index($0, key "=") == 1 { if (!done) { print line; done = 1 } next }
        { print }
        END {
            if (in_section && !done) { print line; done = 1 }
            if (!seen) { print ""; print "[" section "]"; print line }
        }
    ' "$CONF_FILE" > "$tmp" && cat "$tmp" > "$CONF_FILE"
    rm -f "$tmp"
}

echo "[qbt-init] Configuring WebUI..."
# WebUI: Listen on all interfaces, bypass auth for private networks.
# qBittorrent 5.3 moved these from [Preferences] (keys "WebUI\...") into their
# own [WebUI] section. Write them where this config keeps them: before 5.3, and
# on 5.3's first start (which then migrates them), that is [Preferences].
if grep -qx '\[WebUI\]' "$CONF_FILE"; then
    webui_section="WebUI"
    webui_prefix=""
else
    webui_section="Preferences"
    webui_prefix="WebUI\\"
fi
set_config "$webui_section" "${webui_prefix}Address" "*"
# Host-header validation is the defense against DNS rebinding (a web page that
# re-points its own name to this computer, then calls the API as same-origin).
# Accept only the names the clients use: localhost (the browser on the host,
# qSticky, Firefox's Torrent Control) and 127.0.0.1 (the browser on the host).
# qBittorrent also accepts an address equal to the one the connection arrived
# at, but host connections arrive at the container's own address, not 127.0.0.1.
# The quotes are part of the value: in Qt's INI format an unquoted ";" starts a
# comment (qBittorrent would read just "localhost"), and Qt writes it this way.
set_config "$webui_section" "${webui_prefix}HostHeaderValidation" "true"
set_config "$webui_section" "${webui_prefix}ServerDomains" '"localhost;127.0.0.1"'
set_config "$webui_section" "${webui_prefix}AuthSubnetWhitelist" "192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8"
set_config "$webui_section" "${webui_prefix}AuthSubnetWhitelistEnabled" "true"
set_config "$webui_section" "${webui_prefix}LocalHostAuth" "false"

echo "[qbt-init] Configuring connection settings..."
# Connection: Disable UPnP/NAT-PMP (qSticky handles port forwarding via Gluetun)
set_config "Network" "PortForwardingEnabled" "false"

echo "[qbt-init] Configuring download paths..."
set_config "BitTorrent" 'Session\DefaultSavePath' "/downloads/"
set_config "BitTorrent" 'Session\TempPath' "/downloads/incomplete/"
set_config "BitTorrent" 'Session\TempPathEnabled' "true"

echo "[qbt-init] Configuring torrent behavior..."
# Torrents: Start immediately, stop after ratio reached
set_config "BitTorrent" 'Session\AddTorrentStopped' "false"
set_config "BitTorrent" 'Session\ShareLimitAction' "Stop"

# The .torrent hand-off from Firefox: qBittorrent adds every .torrent file that
# appears in /watch (Firefox's download folder, see docker-compose.yml) and
# saves it to /downloads/, not by category (automatic torrent management off).
# qBittorrent keeps its watched folders in watched_folders.json next to
# qBittorrent.conf and reads them at start. This adds /watch to the folders
# already there and leaves the others alone, and leaves /watch alone once it is
# there, so options changed in the WebUI stay.
WATCH_DIR=/watch
WATCH_FILE="$(dirname "$CONF_FILE")/watched_folders.json"
WATCH_ENTRY='{"add_torrent_params": {"save_path": "/downloads/", "use_auto_tmm": false}, "recursive": false}'

configure_watch_folder() {
    local current created="" tmp
    if ! command -v jq >/dev/null 2>&1; then
        echo "[qbt-init] jq not found; not adding $WATCH_DIR" >&2
        return
    fi
    # The file's watched folders: one JSON object, or none at all for a missing
    # or empty file. Anything else is left for the user to fix.
    if [[ -e "$WATCH_FILE" ]]; then
        if ! current=$(jq -s 'if length == 0 then {}
                elif length == 1 and (.[0] | type) == "object" then .[0]
                else error("not one JSON object") end' "$WATCH_FILE" 2>/dev/null); then
            echo "[qbt-init] $WATCH_FILE is not a JSON object; not adding $WATCH_DIR (fix or delete the file)" >&2
            return
        fi
    else
        current="{}"
        created=yes
    fi
    # qBittorrent drops a trailing slash from a watched folder's path.
    if jq -e --arg dir "$WATCH_DIR" 'any(keys[]; rtrimstr("/") == $dir)' <<<"$current" >/dev/null; then
        echo "[qbt-init] $WATCH_DIR is already a watched folder"
        return
    fi
    echo "[qbt-init] Adding $WATCH_DIR to the watched folders"
    tmp=$(mktemp)
    if jq --arg dir "$WATCH_DIR" --argjson entry "$WATCH_ENTRY" '. + {($dir): $entry}' \
        <<<"$current" > "$tmp"; then
        # Rewritten in place, so an existing file keeps its owner and mode.
        cat "$tmp" > "$WATCH_FILE"
        # This script runs as root, after the image has given everything in
        # /config to the user qBittorrent runs as: give the new file the same
        # owner, like the rest of /config.
        if [[ -n "$created" && "$EUID" -eq 0 ]]; then
            chown --reference="$CONF_FILE" "$WATCH_FILE"
        fi
    fi
    rm -f "$tmp"
}

echo "[qbt-init] Configuring the watch folder..."
configure_watch_folder

echo "[qbt-init] Configuration complete"
