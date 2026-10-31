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
│  Localhost only: 5800 (Firefox), 9080 (qBittorrent)         │
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

  [Autoheal] ── monitors this stack's containers through [autoheal-proxy]
              ── restarts any that become unhealthy
  [autoheal-proxy] ── the only container with the Docker socket; lets
                      Autoheal list containers and restart one, nothing else
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
- `PUID` and `PGID`: the output of `id -u` and `id -g` (`docker compose` refuses to start without
  them; `./start.sh` fills them in when they are empty)

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

Torrents go to `~/Downloads/vpn-in-container`, and Firefox's downloads (including `.torrent` files
for qBittorrent) to its `downloads/` subfolder. To use another folder, set `DOWNLOADS_PATH` in
`.env` (`${HOME}` works there, `~` does not), and create that folder's `downloads/` instead.

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
- WebUI accepts only the host names `localhost` and `127.0.0.1` (blocks DNS rebinding)
- UPnP/NAT-PMP disabled (qSticky manages port forwarding)
- Download paths set to `/downloads` and `/downloads/incomplete`
- Watch folder `/watch` (Firefox's download folder) added to `watched_folders.json`, saving to
  `/downloads`, so .torrent files downloaded in Firefox are imported. The script adds it only if
  it is missing: watched folders you add, and options you change for `/watch`, are kept

## Start and Stop

```bash
# Start containers, wait until all are healthy (up to 5 minutes), then open the web interfaces.
# Uses PUID/PGID from your environment or .env; only if neither sets them, your own IDs.
# Exits with an error, and shows each service's state, if any service is not healthy in time.
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

### How Firefox Behaves in the Container

- **Private browsing, always:** history, cookies and site data are not kept.
  The mask icon and "Private browsing" label at the right end of the tab strip
  show it is on (Firefox only shows it when it really is).
- **WebRTC shows only the VPN's address:** web pages, video calls included, never see the
  container's own network addresses (the `FF_PREF_WEBRTC_*` entries in `docker-compose.yml`).
- **Your own mouse cursors:** the web UI shows your computer's native cursors
  (see [config/cursors/README.md](config/cursors/README.md)).
- **One window:** Firefox stays a single maximized window, since the container
  has no way to switch between windows.
  - Dropping a tab outside the tab strip leaves it where it was.
  - Pop-ups, Shift+click and "Open in New Window" open tabs instead.
  - Ctrl+N, Ctrl+Shift+P, Ctrl+Shift+N and Ctrl+Shift+W do nothing, and the menu
    items that open or close windows are hidden.
  - Closing the last tab opens a new tab; the window stays.
  - Ctrl+Q still quits Firefox (the image's shutdown script relies on it); the
    container then stops and restarts.
  - Settings: the single-window `FF_PREF_*` entries in `docker-compose.yml`,
    `config/firefox-autoconfig/`, `config/firefox-profile/customKeys.json` and
    `config/firefox-chrome/userChrome.css`.

### Configure Torrent Control (First Time Only)

The Torrent Control extension is pre-installed. Configure it once to enable one-click magnet links:

1. In Firefox (at `http://localhost:5800`), click the Torrent Control extension icon (puzzle piece in toolbar)
2. Click **Options/Settings**
3. Configure:
   - **Server Type**: qBittorrent
   - **Server URL**: `http://localhost:9080` (qBittorrent refuses other host names)
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

Logs are rotated: each service but Autoheal keeps at most three 10 MB files (`x-logging` in
`docker-compose.yml`), whatever the Docker host's default is. `docker compose logs` reads the
older files too. Changing the setting takes effect when a container is recreated
(`docker compose up -d` after the edit).

## Self-Healing & Sleep/Reboot Recovery

The stack automatically recovers from host sleep, reboot, or VPN disconnects using two layers:

**Layer 1 -- Health checks** on every service detect what they can fix:
| Service | Checks | Interval |
|---------|--------|----------|
| VPN (Gluetun) | Built-in VPN health check (reconnects the tunnel itself) | 15s |
| qBittorrent | WebUI API + the VPN's network is live (Gluetun's port 8000) | 10s |
| Firefox | noVNC web UI + the VPN's network is live (Gluetun's port 8000) | 10s |
| qSticky | Gluetun's port 8000 + qBittorrent's port 9080 | 10s |
| Autoheal | Checks for unhealthy containers | 10s |

Firefox, qBittorrent and qSticky share the VPN container's network. If the Gluetun container
restarts, they are left on its old, dead network, where nothing listens on port 8000: they turn
unhealthy within about 30 seconds. They deliberately do not check internet access: during a VPN
outage, Gluetun reconnects the tunnel on its own, and restarting them would not help (it would
close Firefox's tabs and interrupt torrents).

**Layer 2 -- Autoheal** monitors Docker for unhealthy containers and restarts them.

Autoheal is scoped to this project only: it runs with `AUTOHEAL_CONTAINER_LABEL=autoheal`
and each service in this stack carries the `autoheal=true` label. Unhealthy containers
belonging to other Docker Compose projects on the same host are ignored. (Do **not** set
`AUTOHEAL_CONTAINER_LABEL=all` -- that makes autoheal restart every unhealthy container on
the machine.)

Autoheal has no Docker socket of its own. It calls the Docker API through `autoheal-proxy`
(linuxserver/socket-proxy, which is HAProxy), on an internal network with no route out. The
proxy's allowlist, `config/autoheal-proxy/haproxy.cfg`, passes only `GET /_ping`,
`GET /containers/json` and `POST /containers/<full ID>/restart`; everything else gets 403. The
proxy and Autoheal carry no `autoheal=true` label, since Autoheal cannot heal its own path to
Docker; Docker's restart policy brings either back if it exits.

Every service uses `restart: unless-stopped`: Docker restarts a container that exits, and after a
reboot (or a Docker restart) it starts the containers that were running. After
`docker compose stop`, nothing comes back until `docker compose up -d` or `./start.sh`.

**Recovery flow**:
- VPN outage: Gluetun reconnects the tunnel itself (seconds); nothing else restarts.
- Gluetun container restart (for example by Autoheal): the services sharing its network fail their
  port-8000 check → Autoheal restarts them onto the new network → all healthy. Measured with
  `tests/stack/recovery.sh`: about 40-50 seconds (it was about 2.5 minutes with internet-based
  checks every 30-60 seconds).

Additionally, `depends_on: restart: true` ensures `docker compose restart vpn` cascades to all dependent services.

## Verification

### Automated Tests

```bash
tests/stack/run.sh     # the running stack: VPN egress and kill switch, DNS, port forwarding,
                       # qSticky, qBittorrent (API, settings, watch folder), Firefox, Autoheal
                       # and its Docker socket proxy, loopback-only web UI ports
tests/e2e/run.sh       # Firefox in throwaway containers: cursors, single window, private browsing
tests/browser/run.sh   # the patched noVNC in headless Chrome and Firefox
tests/stack/recovery.sh        # DISRUPTIVE: restarts the VPN container and times the recovery
tests/qbittorrent/download.sh  # a real multi-file download between two throwaway qBittorrent
                               # containers (no internet), checked by SHA-256 and recheck
tests/qbittorrent/fresh-install.sh  # the init script on an empty /config (no network): its
                                    # settings and the /watch hand-off, as on a new clone
node --test tests/ && python3 -m unittest discover -s tests   # unit tests
```

`tests/stack/run.sh` changes nothing permanently: it restores qBittorrent's listening port
and removes its test torrent and test containers.

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

This drops the VPN connection the way a real outage does, and checks that qBittorrent's traffic
is blocked instead of leaving from your own IP. The probe goes to an IP address
(`https://1.1.1.1/cdn-cgi/trace`, which answers with the caller's IP), so a DNS failure during the
outage cannot hide a leak.

```bash
# 1. Before: your own IP, then qBittorrent's (the VPN's); they must differ
curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep '^ip='
docker exec qbittorrent curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep '^ip='

# 2. Take the tunnel interface down inside Gluetun, as when the VPN connection drops
docker exec gluetun-vpn ip link set dev tun0 down

# 3. Right away: the same request from qBittorrent must fail, not show your own IP
docker exec qbittorrent curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep '^ip=' ||
  echo "blocked: the kill switch works"

# 4. Gluetun notices and reconnects by itself, usually within a minute; nothing restarts.
#    This prints the VPN's IP once traffic flows again:
until docker exec qbittorrent curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep '^ip='; do
  sleep 5
done
docker compose logs --since 5m vpn | grep 'Connecting to'   # the reconnect
```

The firewall also blocks traffic that tries to go around the tunnel while it is up:
`docker exec gluetun-vpn ping -c 1 -W 3 -I eth0 1.1.1.1` must fail.

`tests/stack/recovery.sh 300 tunnel-down` automates this: it samples Firefox's and qBittorrent's
public IP every few seconds during the outage, fails on any sample that is not the VPN's, and
times each step of the recovery. `tests/stack/run.sh` checks the firewall rules and probes around
the tunnel without disrupting anything.

### Test Self-Healing

```bash
# Restart the VPN container to simulate a VPN reconnect
docker restart gluetun-vpn

# Watch autoheal detect and restart unhealthy services
docker compose logs -f autoheal

# All services should return to healthy within about a minute
watch docker compose ps

# Or measure it (restarts the VPN container, then times each service's recovery)
tests/stack/recovery.sh
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
2. Check qBittorrent watch folder is `/watch` (Options → Downloads → Monitored folders). The init
   script adds it at every start if `config/qbittorrent/qBittorrent/watched_folders.json` lacks
   it, and leaves the file alone if it is not valid JSON (see `docker compose logs qbittorrent`)
3. Verify `~/Downloads/vpn-in-container/downloads` (or `$DOWNLOADS_PATH/downloads`) exists and has
   correct permissions

### Can't Access Web UIs

1. Ensure ports 5800 and 9080 aren't used by other apps
2. Check VPN container is healthy: `docker compose ps`
3. Try using `localhost` instead of `127.0.0.1`
4. Use this computer: the ports are bound to 127.0.0.1, so other devices, and this computer's LAN IP
   or `.local` name, cannot reach them by design (see [Security Notes](#security-notes))
5. qBittorrent answers "Unauthorized" when opened by a name other than `localhost` or `127.0.0.1`

## File Structure

```
vpn-in-container/
├── docker-compose.yml      # Main configuration
├── .env                    # Your credentials (gitignored)
├── .env.example            # Template
├── config/
│   ├── autoheal-proxy/
│   │   └── haproxy.cfg     # Docker API allowlist for Autoheal (list, restart by ID)
│   ├── cursors/
│   │   ├── README.md       # How native cursors work; upgrading the image
│   │   ├── generate_native_theme.py  # Generates native-css/
│   │   └── native-css/     # Marker cursor theme (shows your OS's native cursors)
│   ├── gluetun/
│   │   ├── config.toml.example  # Template for API authentication
│   │   └── config.toml          # Your API key (gitignored)
│   ├── firefox/            # Browser profile (gitignored)
│   ├── firefox-autoconfig/
│   │   ├── autoconfig.js   # Loads single-window.cfg (Firefox autoconfig)
│   │   └── single-window.cfg  # Moves any second window's tabs into the first window
│   ├── firefox-chrome/
│   │   └── userChrome.css  # No toolbar window dragging; hides new/close window menu items
│   ├── firefox-profile/
│   │   └── customKeys.json # Clears the new-window and close-window shortcuts
│   ├── firefox-init.d/
│   │   ├── 57-openbox-no-keepborder.sh  # Removes the 1px top border (unthemed cursor strip)
│   │   └── 58-openbox-no-alt-drag.sh    # Removes Openbox's Alt+drag move/resize bindings
│   ├── firefox-policies/
│   │   └── policies.json   # Pre-installs Torrent Control extension
│   ├── novnc/
│   │   ├── cursor.js       # Patched noVNC cursor: shows native cursors
│   │   ├── cursor-keyword.js  # Recognizes marker cursors and Openbox's core glyphs
│   │   ├── core-glyphs.js  # Openbox's 11 core glyphs as the VNC server sends them
│   │   └── core-glyphs/capture.sh  # Regenerates core-glyphs.js from the pinned image
│   ├── qbittorrent/        # Torrent client config (gitignored)
│   └── qbittorrent-init.d/
│       └── 10-configure-qbittorrent.sh  # Auto-configures qBittorrent settings
├── tests/
│   ├── cursor-keyword.test.mjs        # node --test tests/
│   ├── test_generate_native_theme.py  # python3 -m unittest discover -s tests
│   ├── test_make_core_glyph_table.py
│   ├── e2e/run.sh          # Real Firefox + VNC server cursor test (Docker)
│   ├── stack/run.sh        # Running stack: VPN, kill switch, ports, qBittorrent, Autoheal
│   ├── qbittorrent/download.sh  # Isolated real download test for the qBittorrent image
│   ├── qbittorrent/fresh-install.sh  # The init script on an empty /config (watch folder)
│   └── browser/run.sh      # Patched noVNC in headless Chrome and Firefox

~/Downloads/vpn-in-container/           # Host downloads directory (DOWNLOADS_PATH in .env)
├── downloads/              # Firefox downloads + .torrent file handoff
├── incomplete/             # In-progress torrent downloads
└── [completed torrents]    # Completed downloads
```

## Security Notes

- The `.env` file contains your VPN credentials - never commit it
- The web UIs are published on 127.0.0.1 only (`docker-compose.yml`), so only this computer can
  reach them. Other devices on your network cannot, and neither can this computer's own LAN IP or
  `.local` name. To use them from another device, tunnel over SSH instead of publishing them on
  the LAN: `ssh -L 5800:localhost:5800 -L 9080:localhost:9080 <this computer>`
- Firefox has no password (anyone who can reach port 5800 controls the browser)
- qBittorrent WebUI bypasses authentication for private networks (192.168.x.x, 172.16.x.x, 10.x.x.x) and localhost.
  Connections through the published port arrive from Docker's bridge gateway, a private address.
- qBittorrent's own password is never set by this stack. Since 4.6.1 it has no default: until you
  set one (Options → WebUI), each start prints a temporary password in `docker compose logs
  qbittorrent`, which you need only from an address outside the bypass. `QBITTORRENT_PASS` in
  `.env` is optional and does not change it: it is only what qSticky sends when it logs in, and
  over loopback qBittorrent does not check it. Set it to the WebUI password only if you turn on
  authentication for localhost (`LocalHostAuth`); a wrong value then fails every 30 seconds, and
  qBittorrent bans 127.0.0.1 for an hour after 5 failures.
- qBittorrent accepts only the host names `localhost` and `127.0.0.1` (`ServerDomains`, set by the
  init script). That stops DNS rebinding, where a web page in any browser on this computer points
  its own name at 127.0.0.1 to call the API. Opening the WebUI by any other name gives
  "Unauthorized".
- All traffic is blocked if VPN disconnects (kill switch)
- DNS queries go through the VPN (DNS-over-TLS)
- Container hardening (`docker-compose.yml`), on every service except Autoheal:
  - `no-new-privileges`: no setuid, setgid or file-capability binary can raise a process's
    privileges. The images' init starts as root and drops to its user with syscalls,
    which this does not affect.
  - Capabilities: each service drops all of them and adds back only what its image needs: Gluetun
    `NET_ADMIN`, `NET_RAW`, `CHOWN`, `DAC_OVERRIDE`; Firefox `CHOWN`, `DAC_OVERRIDE`, `FOWNER`,
    `SETUID`, `SETGID`, `KILL`, `NET_BIND_SERVICE`; qBittorrent `CHOWN`, `DAC_OVERRIDE`,
    `SETUID`, `SETGID`, `KILL`; qSticky and the socket proxy none. The comments in
    `docker-compose.yml` say what breaks without each.
  - Process and memory limits (`pids_limit`, `mem_limit`), so a runaway process stops in its own
    container instead of slowing the computer. Each is well above the peak measured: Firefox
    8 GB and 4096 processes and threads (20 busy tabs used 4.3 GB and 1,311), qBittorrent 2 GB,
    Gluetun 512 MB, qSticky 256 MB, the socket proxy 128 MB. A container that runs out restarts
    (Firefox loses its tabs); raise `mem_limit` in `docker-compose.yml` if you keep many more
    tabs open.
  - Read-only root filesystems for Firefox, qSticky and the socket proxy, with tmpfs mounts where
    they write (`/tmp` and `/run`; qSticky's `/app/health`). Not for Gluetun, which writes
    `/etc/passwd` and `/etc/resolv.conf` at start, or qBittorrent, whose image ignores
    `PUID`/`PGID` when read-only.
- Only `autoheal-proxy` mounts the Docker socket. The `:ro` on that mount does not limit the
  API (a read-only mount does not stop connecting to a socket, and every API call, writes
  included, goes over that connection); the proxy's allowlist does. Autoheal
  can list containers and restart one by ID, and gets 403 for anything else, such as creating
  a container, reading a container's environment (`GET /containers/<id>/json`), exec, stop or
  kill. Restarts are not limited to this project: HAProxy cannot see labels, so a compromised
  Autoheal could restart (not stop or change) any container on this host.

## Disclaimer

This project is provided for legitimate privacy and network isolation purposes. Users are responsible for complying with applicable laws and the terms of service of their VPN provider. The authors do not condone or encourage copyright infringement or any illegal activity.

## License

[GPL v3](LICENSE)
