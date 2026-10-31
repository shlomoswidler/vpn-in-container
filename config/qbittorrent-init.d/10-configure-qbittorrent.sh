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
set_config "$webui_section" "${webui_prefix}ServerDomains" "*"
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

echo "[qbt-init] Configuration complete"
