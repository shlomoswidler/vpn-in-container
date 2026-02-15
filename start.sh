#!/bin/bash

# Start VPN container stack and open web interfaces

set -e

cd "$(dirname "$0")"

# Cross-platform URL opener
open_url() {
    local url="$1"
    if command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "$url"
    else
        echo "  Open manually: $url"
    fi
}

# Auto-detect user/group IDs and download path
export PUID="${PUID:-$(id -u)}"
export PGID="${PGID:-$(id -g)}"
export DOWNLOADS_PATH="${DOWNLOADS_PATH:-$HOME/Downloads/vpn-in-container}"

echo "Starting containers..."
docker compose up -d

echo "Waiting for services to be ready..."
# Wait for VPN to be healthy (other services depend on it)
while ! docker compose ps vpn | grep -q "healthy"; do
    sleep 2
done

# Give qBittorrent and Firefox a moment to start
sleep 5

echo "Opening web interfaces..."
open_url "http://localhost:5800"  # Firefox
open_url "http://localhost:9080"  # qBittorrent

echo "Done! Services are running."
echo "  Firefox:     http://localhost:5800"
echo "  qBittorrent: http://localhost:9080"
