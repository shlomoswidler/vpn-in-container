#!/bin/bash
# Configure qBittorrent settings on container start
# Ensures proper configuration persists across restarts

CONF_FILE="/config/qBittorrent/qBittorrent.conf"

echo "[qbt-init] Starting qBittorrent configuration..."

# Wait for config file to exist (created on first run)
for i in {1..30}; do
    if [[ -f "$CONF_FILE" ]]; then
        break
    fi
    sleep 1
done

if [[ ! -f "$CONF_FILE" ]]; then
    echo "[qbt-init] Config file not found, skipping"
    exit 0
fi

# Function to set a config value (handles any key, updates in place)
set_config() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$CONF_FILE"; then
        # Key exists, update it
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONF_FILE"
    else
        # Key doesn't exist - add after appropriate section header
        local section=""
        case "$key" in
            Session\\\\*|MergeTrackersEnabled)
                section="BitTorrent"
                ;;
            PortForwardingEnabled|Cookies*|Proxy\\\\*)
                section="Network"
                ;;
            *)
                section="Preferences"
                ;;
        esac
        sed -i "/^\[${section}\]/a ${key}=${value}" "$CONF_FILE"
    fi
}

echo "[qbt-init] Configuring WebUI..."
# WebUI: Listen on all interfaces, bypass auth for private networks
set_config "WebUI\\\\Address" "*"
set_config "WebUI\\\\ServerDomains" "*"
set_config "WebUI\\\\AuthSubnetWhitelist" "192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8"
set_config "WebUI\\\\AuthSubnetWhitelistEnabled" "true"
set_config "WebUI\\\\LocalHostAuth" "false"

echo "[qbt-init] Configuring connection settings..."
# Connection: Disable UPnP/NAT-PMP (qSticky handles port forwarding via Gluetun)
set_config "Connection\\\\UPnP" "false"
set_config "PortForwardingEnabled" "false"

echo "[qbt-init] Configuring download paths..."
# Downloads: Set save paths in [Preferences]
set_config "Downloads\\\\SavePath" "/downloads/"
set_config "Downloads\\\\TempPath" "/downloads/incomplete/"
set_config "Downloads\\\\TempPathEnabled" "true"
# Downloads: Set save paths in [BitTorrent] session
set_config "Session\\\\DefaultSavePath" "/downloads/"
set_config "Session\\\\TempPath" "/downloads/incomplete/"
set_config "Session\\\\TempPathEnabled" "true"

echo "[qbt-init] Configuring torrent behavior..."
# Torrents: Start immediately, stop after ratio reached
set_config "Session\\\\AddTorrentStopped" "false"
set_config "Session\\\\ShareLimitAction" "Stop"

echo "[qbt-init] Configuration complete"
