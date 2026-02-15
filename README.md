# Containerized VPN Browser Stack

A Docker Compose stack providing a privacy-focused, containerized browsing environment. Routes Firefox and qBittorrent through a WireGuard VPN with automatic kill switch, health monitoring, and self-healing recovery.

## Features

- **Firefox browser** accessible via web interface (noVNC) at `http://localhost:5800`
- **qBittorrent** with web UI at `http://localhost:9080`
- **Automatic torrent handoff**: Download `.torrent` files in Firefox → qBittorrent auto-imports them
- **Automatic port forwarding**: qSticky syncs the VPN's forwarded port to qBittorrent
- **Kill switch**: All traffic blocked if VPN drops
- **Self-healing**: Health checks on all services + autoheal automatically recovers from sleep/reboot
- **Single command startup**: `docker compose up -d`

## Use Cases

- **Private browsing**: Isolate VPN-tunneled browsing from your host without configuring system-wide VPN
- **Downloading large files**: Bandwidth-managed downloads via torrent protocol (Linux ISOs, open-source releases, datasets)
- **Network isolation**: Containerized environment with guaranteed VPN routing and kill switch

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Gluetun VPN Container                     │
│  WireGuard → ProtonVPN │ Kill Switch │ Port Forwarding      │
│  Exposed: 5800 (Firefox), 9080 (qBittorrent)                │
└─────────────────────────────────────────────────────────────┘
                    │ All traffic routed through VPN
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   [Firefox]   [qBittorrent]  [qSticky]
        │           │             │
        └─────┬─────┘             │
              ▼                   │
  ~/Downloads/vpn-in-container/   │
         downloads/  ←───────────┘
              │       (auto port sync)
              ▼
  ~/Downloads/vpn-in-container/

  [Autoheal] ── monitors all containers via Docker socket
              ── restarts any that become unhealthy
```

## Prerequisites

1. **Docker Engine** or **Docker Desktop** (macOS: OrbStack also works)
2. **ProtonVPN** account (paid plan required for port forwarding)

## Quick Start

### 1. Generate ProtonVPN WireGuard Configuration

1. Go to [ProtonVPN WireGuard Configuration](https://account.proton.me/u/0/vpn/WireGuard)
2. Click "Create new config"
3. **Important**: Enable "NAT-PMP (Port Forwarding)" option
4. Select your preferred server location
5. Download or view the configuration
6. Copy the `PrivateKey` value (looks like `aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789+/=`)

### 2. Create Environment File

```bash
# Copy the template
cp .env.example .env

# Generate a random API key for Gluetun control server
openssl rand -hex 32
# Copy this value for the next step

# Edit .env with your values
nano .env  # or use your preferred editor
```

Fill in these required values:
- `WIREGUARD_PRIVATE_KEY`: Your ProtonVPN WireGuard private key
- `GLUETUN_API_KEY`: The random key you generated above

> **Note:** The `.env.example` includes `COMPOSE_PROJECT_NAME=vpn-in-container`. Do not remove this — it prevents Docker Compose from normalizing hyphens to underscores in volume mount paths, which would break all container configurations. See [Troubleshooting](#containers-start-with-empty-config--wrong-mount-paths) for details.

### 3. Update Gluetun Config

```bash
cp config/gluetun/config.toml.example config/gluetun/config.toml
```

Edit `config/gluetun/config.toml` and replace `REPLACE_WITH_GLUETUN_API_KEY` with the same API key from step 2:

```toml
[[roles]]
name = "qsticky"
routes = ["GET /v1/portforward", "GET /v1/vpn/status"]
auth = "apikey"
apikey = "your_actual_api_key_here"
```

### 4. Create Downloads Directory

```bash
mkdir -p "$HOME/Downloads/vpn-in-container/downloads"
```

### 5. Start the Stack

```bash
docker compose up -d
```

### 6. Verify qBittorrent

Open qBittorrent at `http://localhost:9080` - **no login required** from your host machine.

All settings are automatically configured by the init script:
- WebUI authentication bypassed for private networks
- UPnP/NAT-PMP disabled (qSticky manages port forwarding)
- Download paths set to `/downloads` and `/downloads/incomplete`
- Watch folder enabled at `/watch` for auto-importing .torrent files

## Start and Stop

```bash
# Start containers and open web interfaces
./start.sh

# Or start manually without opening browser
docker compose up -d

# Stop all containers (preserves state for quick restart)
docker compose stop
```

## Usage

| Service | URL | Description |
|---------|-----|-------------|
| Firefox | http://localhost:5800 | Browser (no password) |
| qBittorrent | http://localhost:9080 | Torrent client (no password from host) |

### Configure Torrent Control (First Time Only)

The Torrent Control extension is pre-installed. Configure it once to enable one-click magnet links:

1. In Firefox (at `http://localhost:5800`), click the Torrent Control extension icon (puzzle piece in toolbar)
2. Click **Options/Settings**
3. Configure:
   - **Server Type**: qBittorrent
   - **Server URL**: `http://localhost:9080`
   - **Username/Password**: Leave empty (auth bypassed within container network)

Now clicking any magnet link will automatically add it to qBittorrent.

### Workflow: .torrent Files

1. Open Firefox at `http://localhost:5800`
2. Download a `.torrent` file
3. The file is saved to the watch folder
4. qBittorrent automatically picks it up and starts downloading
5. Completed files appear in `~/Downloads/vpn-in-container`

### Workflow: Magnet Links

**With Torrent Control extension (recommended):**
- Just click the magnet link - it's sent to qBittorrent automatically

**Without extension:**
1. Right-click the magnet link → **Copy Link**
2. Open the noVNC sidebar (arrow on left edge of screen)
3. Click the **clipboard icon** - your copied link appears there
4. Select and copy the text from the clipboard panel (now on your host clipboard)
5. Go to qBittorrent (`http://localhost:9080`)
6. Press `O` or click the link icon → paste the magnet link

## Commands

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f

# View specific service logs
docker compose logs vpn
docker compose logs firefox
docker compose logs qbittorrent
docker compose logs qsticky

# Restart VPN (connects to new server; dependent services cascade-restart)
docker compose restart vpn

# Check VPN IP address
docker exec gluetun-vpn wget -qO- ifconfig.me/ip

# Check health status of all services
docker compose ps

# View autoheal activity (restart events)
docker compose logs autoheal
```

## Self-Healing & Sleep/Reboot Recovery

The stack automatically recovers from host sleep, reboot, or VPN disconnects using two layers:

**Layer 1 -- Health checks** on every service detect broken connectivity:
| Service | Checks | Interval |
|---------|--------|----------|
| VPN (Gluetun) | Built-in WireGuard health check | 15s |
| qBittorrent | API responsiveness + internet via VPN | 30s |
| Firefox | noVNC server + internet via VPN | 60s |
| qSticky | Gluetun API + qBittorrent reachability | 60s |
| Autoheal | Built-in | 5s |

**Layer 2 -- Autoheal** monitors Docker for unhealthy containers and restarts them.

**Recovery flow**: VPN drops → health checks fail on dependent services → autoheal restarts them → they rejoin the recovered VPN namespace → all services return to healthy (~3-4 minutes).

Additionally, `depends_on: restart: true` ensures `docker compose restart vpn` cascades to all dependent services.

## Verification

### Test VPN Connection

```bash
# Your real IP
curl -s ifconfig.me

# VPN IP (should be different)
docker exec gluetun-vpn wget -qO- ifconfig.me/ip
```

### Test Health Checks

```bash
# All services should show "(healthy)"
docker compose ps

# Check individual health details
docker inspect --format='{{.State.Health.Status}}' gluetun-vpn
docker inspect --format='{{.State.Health.Status}}' qbittorrent
docker inspect --format='{{.State.Health.Status}}' firefox-novnc
docker inspect --format='{{.State.Health.Status}}' qsticky
```

### Test Kill Switch

```bash
# Stop VPN
docker compose stop vpn

# Try to access internet (should fail/timeout)
docker exec gluetun-vpn wget -qO- --timeout=5 ifconfig.me/ip

# Restart VPN
docker compose start vpn
```

### Test Self-Healing

```bash
# Restart the VPN container to simulate a VPN reconnect
docker restart gluetun-vpn

# Watch autoheal detect and restart unhealthy services
docker compose logs -f autoheal

# All services should return to healthy within ~3-4 minutes
watch docker compose ps
```

### Test Port Forwarding

```bash
# Check qSticky logs for port sync
docker compose logs qsticky

# Should show messages like:
# "Port forwarding active: 12345"
# "Updated qBittorrent listening port to 12345"
```

### Test DNS Leak

1. Open Firefox at `http://localhost:5800`
2. Visit https://dnsleaktest.com
3. Run "Extended test"
4. DNS servers should show Cloudflare or similar privacy DNS, **not your ISP**
5. Your public IP should show the VPN IP, not your real IP

## Troubleshooting

### VPN Won't Connect

```bash
docker compose logs vpn
```

Common issues:
- Invalid `WIREGUARD_PRIVATE_KEY` - regenerate from ProtonVPN
- Server unavailable - try different `SERVER_COUNTRIES` in `.env`

### qBittorrent Shows "Stalled"

- Verify port forwarding is working: `docker compose logs qsticky`
- Ensure UPnP/NAT-PMP is disabled in qBittorrent settings
- Check if VPN supports port forwarding (requires paid ProtonVPN)

### Services Broken After Sleep/Reboot

The stack self-heals automatically. If services remain unhealthy after ~5 minutes:
```bash
# Check what's unhealthy
docker compose ps

# Check autoheal is running and restarting things
docker compose logs autoheal

# Nuclear option: restart everything
docker compose down && docker compose up -d
```

### Firefox/qBittorrent Won't Start

These services wait for VPN to be healthy. Check VPN status:
```bash
docker compose ps
docker compose logs vpn
```

### Containers Start With Empty Config / Wrong Mount Paths

Docker Compose v2 normalizes the project name by replacing hyphens with underscores. This can cause relative volume mounts (e.g. `./config/firefox`) to resolve to `vpn_in_container/config/...` instead of `vpn-in-container/config/...`. When this happens, Docker auto-creates empty directories at the wrong path and containers start with no configuration.

**Symptoms:**
- qBittorrent generates a random temporary password on every start
- qSticky logs show `Failed to get preferences: 403`
- Firefox starts but crashes or has no saved profile
- A ghost `vpn_in_container/` directory appears alongside the real project

**Fix:** Ensure `COMPOSE_PROJECT_NAME=vpn-in-container` is set in your `.env` file (included in `.env.example`). Then clean up and restart:
```bash
# Remove ghost directory if it exists
rm -rf /path/to/vpn_in_container

# Recreate containers
docker compose down && docker compose up -d
```

### Watch Folder Not Working

1. Verify Firefox download location is `/config/downloads`
2. Check qBittorrent watch folder is `/watch`
3. Verify `~/Downloads/vpn-in-container/downloads` exists and has correct permissions

### Can't Access Web UIs

1. Ensure ports 5800 and 9080 aren't used by other apps
2. Check VPN container is healthy: `docker compose ps`
3. Try using `localhost` instead of `127.0.0.1`

## File Structure

```
vpn-in-container/
├── docker-compose.yml      # Main configuration
├── .env                    # Your credentials (gitignored)
├── .env.example            # Template
├── config/
│   ├── gluetun/
│   │   ├── config.toml.example  # Template for API authentication
│   │   └── config.toml          # Your API key (gitignored)
│   ├── firefox/            # Browser profile (gitignored)
│   ├── firefox-policies/
│   │   └── policies.json   # Pre-installs Torrent Control extension
│   ├── qbittorrent/        # Torrent client config (gitignored)
│   └── qbittorrent-init.d/
│       └── 10-configure-qbittorrent.sh  # Auto-configures qBittorrent settings

~/Downloads/vpn-in-container/           # Host downloads directory
├── downloads/              # Firefox downloads + .torrent file handoff
├── incomplete/             # In-progress torrent downloads
└── [completed torrents]    # Completed downloads
```

## Security Notes

- The `.env` file contains your VPN credentials - never commit it
- Firefox has no password by default (access is local only)
- qBittorrent WebUI bypasses authentication for private networks (192.168.x.x, 172.16.x.x, 10.x.x.x) and localhost
- All traffic is blocked if VPN disconnects (kill switch)
- DNS queries go through the VPN (DNS-over-TLS)
- Autoheal has read-only access to the Docker socket for health monitoring

## Disclaimer

This project is provided for legitimate privacy and network isolation purposes. Users are responsible for complying with applicable laws and the terms of service of their VPN provider. The authors do not condone or encourage copyright infringement or any illegal activity.

## License

[GPL v3](LICENSE)
