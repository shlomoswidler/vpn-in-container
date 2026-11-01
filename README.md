# Containerized VPN Browser Stack

A Docker Compose stack providing a privacy-focused, containerized browsing environment. Routes Firefox and qBittorrent through a WireGuard VPN with automatic kill switch, health monitoring, and self-healing recovery.

## Features

- **Firefox browser** accessible via web interface (noVNC) at `http://localhost:5800`, with sound
- **Optional permanent private browsing**: `FIREFOX_PRIVATE_BROWSING=true` in `.env` (off by
  default)
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
              ── restarts any that become unhealthy (built here from a fixed commit)
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

# Generate a random API key for Gluetun's control server
openssl rand -hex 32
# Put this value in GLUETUN_API_KEY

# Edit .env with your values
nano .env  # or use your preferred editor
```

Fill in these required values:
- `WIREGUARD_PRIVATE_KEY`: Your ProtonVPN WireGuard private key
- `GLUETUN_API_KEY`: The random key you generated above. It is the only copy: Compose writes
  Gluetun's auth file from it and gives it to qSticky (see [Changing the API
  Key](#changing-the-api-key))
- `PUID` and `PGID`: the output of `id -u` and `id -g` (`docker compose` refuses to start without
  them; `./start.sh` fills them in when they are empty)

Optional:
- `FIREFOX_PRIVATE_BROWSING`: `true` to make Firefox always browse in private mode; unset or
  `false` (the default) for normal browsing. See [Private
  Browsing](#private-browsing-firefox_private_browsing).
- `DOWNLOADS_PATH`: where downloads go (see step 3).

> **Note:** The `.env.example` includes `COMPOSE_PROJECT_NAME=vpn-in-container`. Do not remove this — it prevents Docker Compose from normalizing hyphens to underscores in volume mount paths, which would break all container configurations. See [Troubleshooting](#containers-start-with-empty-config--wrong-mount-paths) for details.

> **Upgrading from an earlier version:** the API key used to be kept a second time, in
> `config/gluetun/config.toml`. That file is no longer read, but it still holds the key in plain
> text: delete it (`rm config/gluetun/config.toml`).

### 3. Create Downloads Directory

Torrents go to `~/Downloads/vpn-in-container`, and Firefox's downloads (including `.torrent` files
for qBittorrent) to its `downloads/` subfolder. To use another folder, set `DOWNLOADS_PATH` in
`.env` (`${HOME}` works there, `~` does not), and create that folder's `downloads/` instead.

```bash
mkdir -p "$HOME/Downloads/vpn-in-container/downloads"
```

### 4. Start the Stack

```bash
docker compose up -d
```

### 5. Verify qBittorrent

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

- **Private browsing only if you turn it on:** see [Private
  Browsing](#private-browsing-firefox_private_browsing) below. Off by default.
- **WebRTC shows only the VPN's address:** web pages, video calls included, never see the
  container's own network addresses (the `FF_PREF_WEBRTC_*` entries in `docker-compose.yml`).
- **Your own mouse cursors:** the web UI shows your computer's native cursors
  (see [config/cursors/README.md](config/cursors/README.md)).
- **One window of each kind, all full size:** every Firefox window is maximized over the whole
  display (Openbox, the container's window manager, does that for every Firefox window), and
  Firefox keeps at most one normal window and one private window, since the container has no
  way to arrange windows.
  - Dropping a tab outside the tab strip leaves it where it was.
  - Pop-ups (`window.open()`, with or without a size), `target="_blank"` links, Shift+click and
    "Open in New Window" open tabs instead, in the window of the page they came from: a new
    window's tabs move into the open window of the same kind, normal or private.
  - Private windows open as in Firefox itself: Ctrl+Shift+P, "New private window" in the app
    menu and the File menu, "Open Link in New Private Window". When a private window is already
    open, a new one's tabs join it.
  - **Switching windows** (private browsing off): a window covers the other (both are full
    size). Press **Ctrl+`** (Control and the key left of 1; on a Mac too, Control, not Command)
    to show the other window, or use the **Window** menu in the menu bar and choose a window
    (they are numbered: Alt+W, then 1 or 2). The menu bar shows while Alt is held, or always
    after right-clicking the tab strip and choosing Menu Bar. Firefox has no Window menu of its
    own on Linux; `config/firefox-autoconfig/single-window.cfg` adds it. Right after a window
    opens, give it a second: a switch within a fraction of a second of it showing can be lost.
    (Ctrl+` is tested through the web UI in headless Chrome and Firefox; the Alt keys were
    tested inside the container, not from a Mac keyboard, where Option may not arrive as Alt.)
  - **Closing a window** (private browsing off): Ctrl+Shift+W, File > Close Window or Window >
    Close Window close the window shown, for example the private window, which takes you back
    to the normal one. Closing the last window quits Firefox, and it starts again with a fresh
    normal window (see Quit & Restart below; nothing is reopened).
  - **With private browsing on there is only one window,** since every window is private: no
    Window menu, no Ctrl+`, and no Close Window (the menu item is hidden, Ctrl+Shift+W does
    nothing).
  - **Quit & Restart** (Ctrl+Q, File > Quit & Restart, or Quit & Restart at the bottom of the ☰
    menu) asks first, then quits Firefox, and the container starts it again within about 20
    seconds; the web UI stays connected. With private browsing on, that clears the session's
    cookies, history and site data, without touching Docker. With it off, the tabs of the normal
    window come back, as after Firefox's own restart; private windows do not.
  - **Firefox never stops the container:** if Firefox exits for any reason (Quit & Restart,
    closing its last window, a crash), the container starts it again
    (`KEEP_APP_RUNNING=1`); only Docker stops the container. When it does (`docker stop`, `docker
    compose down`), the image's shutdown script quits Firefox so it saves its profile; it presses
    Ctrl+Alt+Shift+Q here, which quits without asking
    (`config/firefox-services/kill`, the image's script with that key). Pressing that key
    yourself is a Quit & Restart without the question.
  - Ctrl+N and Ctrl+Shift+N do nothing, and the menu items that open a normal window are hidden.
  - Closing the last tab opens a new tab; the window stays.
  - Settings: the single-window `FF_PREF_*` entries in `docker-compose.yml`,
    `config/firefox-autoconfig/`, `config/firefox-profile/customKeys.json` and
    `config/firefox-chrome/userChrome.css`.

### Private Browsing (`FIREFOX_PRIVATE_BROWSING`)

Off by default, as in Firefox itself. To turn it on, add this line to `.env` (the commented
example is in `.env.example`) and run `docker compose up -d`:

```bash
FIREFOX_PRIVATE_BROWSING=true
```

- **On (`true`):** Firefox always browses in private mode. History, cookies (and with them the
  sites you are signed in to) and site data last only until Firefox restarts (Quit & Restart,
  Ctrl+Q, or the container restarting), so sites can't recognize you from one session to the
  next. The mask icon and "Private
  browsing" label at the right end of the tab strip show it is on (Firefox only shows it when
  it really is).
- **Off (unset, empty or `false`):** a normal Firefox profile. History, cookies, logins and site
  data are kept in `./config/firefox` on your host, and sites can recognize you across sessions,
  as in any browser (still through the VPN: they see the VPN's address, not yours). Anyone who
  can read that folder can read them.
- **Switching:** change the line in `.env` and run `docker compose up -d`; the firefox container
  is recreated and the change applies at that start, in either direction. What a normal session
  saved stays in `./config/firefox`; private mode does not show it (its cookies, for example).
  The setting is always written into Firefox's `prefs.js`, `false` included, so turning it off
  on a profile that had it on does turn it off.
- **Only `true` or `false`:** anything else (`yes`, `True`, `1`, a comment right after the
  `=`) would leave private browsing off without a word, so the firefox container exits at start instead,
  with the reason in `docker compose logs firefox`, and `./start.sh` refuses it before starting
  anything. Unset or empty means off.
- **Private windows:** with it off, Firefox opens private windows on request, as Firefox itself
  does (see [How Firefox Behaves](#how-firefox-behaves-in-the-container)); with it on, every
  window is private already.
- **Downloads** go to the same folder either way. With private browsing on, Firefox's first
  download shows a "Files stay on your device" notice with a "Delete files automatically" button,
  which asks Firefox to delete files downloaded in private mode after the private session ends.
  Choose "Got it" to keep downloads (`.torrent` files included) in the downloads folder as usual.
  (Tested with that setting on: a downloaded `.torrent` was still there after the container
  stopped and started again, so do not count on the deletion here either.) With private browsing
  off, downloads are not private, and the notice does not appear.

### Sound

Sound from Firefox in the container plays in the browser tab that shows the web UI
(http://localhost:5800). VNC clients get no sound.

1. **Turn it on once:** open the side panel (the handle on the left edge of the web UI) and
   click the speaker icon, or move the volume slider above 0. The first time, the volume
   starts at 0, so a click anywhere else does not turn sound on.
2. **After that, click once per visit:** the web UI remembers the setting (in your browser's
   storage for localhost:5800). After every page load your browser still blocks sound until
   you interact with the page (its autoplay policy), so sound comes back at your first click
   or tap in the web UI. Keystrokes don't count.
3. **After a reconnect, nothing:** when the container restarts (Autoheal restarting Gluetun
   restarts Firefox with it) and the open tab reconnects, sound comes back on by itself, or
   stays off if you had muted it. The image's web UI leaves it off until you click the
   speaker icon again; `config/novnc/ui.js` (the image's `app/ui.js` plus `ui.js.patch`,
   mounted over it) fixes that.
4. **Sites in the container:** Firefox there keeps its default autoplay setting (block
   audible autoplay): a site plays sound once you click in it, on a play button for
   example. Your clicks reach Firefox as real input, so nothing else is needed.

The stream is raw 44.1 kHz stereo, about 1.4 Mbit/s, sent while sound is on (silence
included), over the same loopback-only port 5800. Everyone viewing the web UI hears the same
sound.

Why the container's Firefox does not allow sites to autoplay sound
(`media.autoplay.default` stays at Firefox's default, 1: block audible autoplay): with it
allowed, any page, an ad included, could start making noise in every open web UI tab. The
click a site needs is the one you would make anyway, and with private browsing on a per-site
"allow" would not last, since private browsing keeps no site permission past a restart (with
it off, a per-site allow is kept like any other site setting). To allow it
anyway, add `- FF_PREF_AUTOPLAY=media.autoplay.default=0` to the firefox service's
`environment:` (tests/e2e/run.sh then checks that it reaches Firefox).

What is tested automatically (see [Automated Tests](#automated-tests)), and what is not:

- `tests/e2e/run.sh` scenario 9: in a throwaway container hardened like the service, a page's
  1000 Hz (left) and 1500 Hz (right) tone, started by a click, reaches PulseAudio, the
  recorder and the web UI's WebSocket unchanged, at the right rate and in whole samples,
  with silence before the click and after the tone stops.
- `tests/browser/run.sh`, in headless Chrome and Firefox: the image's audio player (blocked
  before a gesture, then decoding the stream on the right channels at the set volume); and
  the whole path through the real web UI of such a container, measured at the web UI's own
  audio output: no sound before a gesture, the speaker icon on first use, the first click
  on a later visit, and the tone from the container's page; then, with no click, sound
  coming back after the container restarts and the same tab reconnects, and staying off
  after such a restart if it was muted.
- **Manual: actually hearing it.** The last step, from the browser to your Mac's speakers
  (the output device, the system volume, the tab not muted), and Safari, are not tested.
  Check once after setting up or upgrading: open http://localhost:5800, open the side panel,
  click the speaker icon, then play something with sound in Firefox (any video) and listen.

### Configure Torrent Control (First Time Only)

The Torrent Control extension is pre-installed, and allowed in private windows (every window
with `FIREFOX_PRIVATE_BROWSING=true`, and a private window you open otherwise), both by
`config/firefox-policies/policies.json`. Configure it once to enable one-click magnet
links:

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

Logs are rotated: each service keeps at most three 10 MB files (`x-logging` in
`docker-compose.yml`), whatever the Docker host's default is. `docker compose logs` reads the
older files too. Changing the setting takes effect when a container is recreated
(`docker compose up -d` after the edit).

### Changing the API Key

`GLUETUN_API_KEY` in `.env` is the only copy of the key. Compose writes Gluetun's auth file from it
(`configs: gluetun_auth` in `docker-compose.yml`; `/run/secrets/gluetun_auth.toml` in the
container, readable only by root), with one role: qSticky may read the forwarded port and the VPN
status, nothing else. qSticky gets the key in its environment. After changing it:

```bash
docker compose up -d --force-recreate vpn qsticky
docker compose up -d
```

`--force-recreate` is needed because Compose decides whether to recreate a container from the
service's settings, which name the auth file but do not include its content. A plain
`docker compose up -d` would recreate qSticky, whose environment changed, but leave Gluetun on the
old key: qSticky would get 401 from Gluetun and stop syncing the forwarded port.
`docker compose restart vpn` does not apply it either: Compose copies the file in only when it
starts a container (`up`, `start`). The second, plain `up -d` recreates Firefox: naming services
selects them and what they depend on, not what depends on them, so the first command leaves
Firefox on the removed Gluetun container's network, where it cannot start again.

## Self-Healing & Sleep/Reboot Recovery

The stack automatically recovers from host sleep, reboot, or VPN disconnects using two layers:

**Layer 1 -- Health checks** on every service detect what they can fix:
| Service | Checks | Interval |
|---------|--------|----------|
| VPN (Gluetun) | Built-in VPN health check (reconnects the tunnel itself) | 15s |
| qBittorrent | WebUI API + the VPN's network is live (Gluetun's port 8000) | 10s |
| Firefox | noVNC web UI + the VPN's network is live (Gluetun's port 8000) | 10s |
| qSticky | Gluetun's port 8000 + qBittorrent's port 9080 | 10s |
| Autoheal | Its container list gets through the proxy to Docker (it looks for unhealthy containers every 10s) | 30s |

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

### Autoheal's Image

Autoheal is built on this computer, not pulled. willfarrell/docker-autoheal has no version
tags: its Docker Hub image is `:latest`, rebuilt every day on Alpine 3.18 (no longer
supported), and an old digest loses its tag. `docker-compose.yml` builds the project's one
script, `docker-entrypoint` (MIT license), from GitHub at a fixed commit (the full SHA), on
Alpine pinned by digest, with curl, jq and tzdata from Alpine's packages. It runs as `nobody`,
with a read-only root and no capabilities. The build does not use upstream's Dockerfile, which
fetches an unpinned BuildKit frontend and builds on Alpine 3.18.

- The first `docker compose up -d` (or `./start.sh`) builds it, which needs github.com and
  Alpine's package mirror (dl-cdn.alpinelinux.org) to be reachable. After that, `up` reuses the
  image, offline too. If the repository ever disappears, the built image keeps working; a new
  build would need `docker-entrypoint` copied into this repository (keep its MIT notice) and
  built from a local context.
- `docker compose pull` skips it (`pull_policy: never`): there is nothing to pull. Without that
  setting, a plain `docker compose pull` fails ("pull access denied"); `docker compose pull
  --ignore-buildable` skips it either way. Do not use `docker compose up --pull always`: it
  overrides the policy and looks for the name on Docker Hub.
- Alpine's fixes for curl, jq and tzdata, with nothing else changed:
  `docker compose build --no-cache autoheal && docker compose up -d`.
- A new Alpine (a 3.24.x point release, or a new digest for the same version): get the digest
  with `docker buildx imagetools inspect alpine:<version>` (the first `Digest:` line). In
  `docker-compose.yml`, change the `FROM` line, the two `org.opencontainers.image.base.*`
  labels and the image tag (`<first 7 of the commit>-alpine<version>-<first 12 hex of the
  digest>`) together; `python3 -m unittest discover -s tests` fails if they disagree. The tag
  names the inputs so that `docker compose up -d` builds a new image instead of reusing the one
  built from the old inputs. Then run `docker compose up -d` and `tests/stack/run.sh`, which
  checks that the running image carries the new labels.
- A newer upstream commit: read what changed in `docker-entrypoint` first (it can restart
  containers), in a clone: `git diff f535158 <commit> -- docker-entrypoint`. Then change the
  full SHA in the build `context`, the `org.opencontainers.image.revision` label and the image
  tag together, and run the tests as above.

## Verification

### Automated Tests

```bash
tests/stack/run.sh     # the running stack: VPN egress and kill switch, DNS, port forwarding,
                       # qSticky, qBittorrent (API, settings, watch folder), Firefox, Autoheal
                       # and its Docker socket proxy, loopback-only web UI ports
tests/e2e/run.sh       # Firefox in throwaway containers: cursors, single window, private browsing
                       # on and off (and switching), downloads, WebRTC, sound to the web UI's
                       # audio stream; its scenarios run in groups at the same time, and
                       # `tests/e2e/run.sh 7 8` runs only scenarios 7 and 8
tests/browser/run.sh   # the web UI in headless Chrome and Firefox: the patched noVNC cursor,
                       # the audio player, and sound through the real web UI of a throwaway
                       # container, also across a restart of it; Ctrl+` through the web UI
                       # switching that container's Firefox windows
tests/stack/recovery.sh        # DISRUPTIVE: restarts the VPN container and times the recovery
tests/stack/daemon-restart.sh --yes-restart-docker  # VERY DISRUPTIVE: restarts the Docker
                                                    # engine, so every container on this host:
                                                    # the stack must come back by itself, and
                                                    # stay stopped after `docker compose stop`
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

### Gluetun Warns "failed writing servers to file" (Linux)

Gluetun runs as root but without the `DAC_OVERRIDE` capability, so it can write only into folders
and files that root owns. On a Linux host, `./config/gluetun` belongs to your user, and Gluetun
logs `WARN [storage] failed writing servers to file: open /gluetun/servers.json: permission
denied`. Only the saved copy of its server list is affected: it keeps using its built-in list, and
the VPN works. `tests/stack/run.sh` reports the line as a permission error. To let Gluetun save
the list, give the folder to root: `sudo chown -R 0:0 config/gluetun`. (On macOS with OrbStack or
Docker Desktop, the bind mount's files show as root's inside the container, so this does not
happen.)

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

If Firefox exits right after it starts, check `docker compose logs firefox` for
`FIREFOX_PRIVATE_BROWSING is '...', not true or false`: set it to `true` or `false` in `.env`
(or remove the line), then run `docker compose up -d`.

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

### No Sound in the Web UI

1. No Audio section (speaker icon) in the side panel: the container was created before
   `WEB_AUDIO=1`. `docker compose up -d` recreates it with the new setting; then reload
   the web UI.
2. The icon shows the speaker crossed out: click it once (see [Sound](#sound)). After each
   reload, click anywhere in the web UI once.
3. The icon is on but nothing is heard: check the volume slider, that the browser tab isn't
   muted, and the Mac's output device and volume. In `docker compose logs firefox`, the
   `[audiorecorder]` lines show "new client connected" when the web UI opens the stream
   (PulseAudio, when it works, prints nothing; its lines would start with `[pulseaudio]`).

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
│   ├── gluetun/            # Gluetun's server list, servers.json (gitignored)
│   ├── firefox/            # Browser profile (gitignored)
│   ├── firefox-autoconfig/
│   │   ├── autoconfig.js   # Loads single-window.cfg (Firefox autoconfig)
│   │   └── single-window.cfg  # Moves a new window's tabs into the open window of its kind
│   │                          # (normal or private); Window menu, Ctrl+`, Quit & Restart
│   ├── firefox-chrome/
│   │   └── userChrome.css  # No toolbar window dragging; hides new-window and Quit items
│   ├── firefox-profile/
│   │   └── customKeys.json # Clears the new-window, reopen-window and stock Quit shortcuts
│   ├── firefox-services/
│   │   ├── kill            # Patched shutdown script: quits Firefox with Ctrl+Alt+Shift+Q
│   │   └── kill.patch, kill.upstream.sha256  # How kill differs from the image's
│   ├── firefox-init.d/
│   │   ├── 54-firefox-private-browsing.sh  # Refuses a FIREFOX_PRIVATE_BROWSING but true/false
│   │   ├── 57-openbox-no-keepborder.sh  # Removes the 1px top border (unthemed cursor strip)
│   │   └── 58-openbox-no-alt-drag.sh    # Removes Openbox's Alt+drag move/resize bindings
│   ├── firefox-policies/
│   │   └── policies.json   # Installs Torrent Control, allowed in private windows
│   ├── novnc/
│   │   ├── cursor.js       # Patched noVNC cursor: shows native cursors
│   │   ├── ui.js           # Patched web UI: sound comes back after a reconnect
│   │   ├── *.patch, *.upstream.sha256  # How cursor.js and ui.js differ from the image's
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
│   ├── image_overlays.py   # Checks each patched file is the image's file plus its patch
│   ├── e2e/run.sh          # Real Firefox in throwaway containers: cursors, windows, sound (Docker)
│   ├── stack/run.sh        # Running stack: VPN, kill switch, ports, qBittorrent, Autoheal
│   ├── qbittorrent/download.sh  # Isolated real download test for the qBittorrent image
│   ├── qbittorrent/fresh-install.sh  # The init script on an empty /config (watch folder)
│   └── browser/run.sh      # Patched noVNC, the audio player and Ctrl+` in headless Chrome and Firefox

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
- Container hardening (`docker-compose.yml`), on every service:
  - `no-new-privileges`: no setuid, setgid or file-capability binary can raise a process's
    privileges. The images' init starts as root and drops to its user with syscalls,
    which this does not affect.
  - Capabilities: each service drops all of them and adds back only what its image needs: Gluetun
    `NET_ADMIN`, `NET_RAW`; Firefox `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `KILL`,
    `NET_BIND_SERVICE`; qBittorrent `CHOWN`, `DAC_OVERRIDE`, `SETUID`, `SETGID`, `KILL`; qSticky,
    Autoheal and the socket proxy none. The comments in `docker-compose.yml` say what breaks
    without each. Gluetun writes its status files (the forwarded port) as root's (`PUID=0`) in a
    tmpfs it can search, so it needs neither `CHOWN` nor `DAC_OVERRIDE`.
  - Process and memory limits (`pids_limit`, `mem_limit`), so a runaway process stops in its own
    container instead of slowing the computer. Each is well above the peak measured: Firefox
    8 GB and 4096 processes and threads (20 busy tabs used 4.3 GB and 1,311), qBittorrent 2 GB,
    Gluetun 512 MB, qSticky 256 MB, the socket proxy 128 MB, Autoheal 64 MB. A container that
    runs out restarts (Firefox loses its tabs); raise `mem_limit` in `docker-compose.yml` if you
    keep many more tabs open.
  - Read-only root filesystems for Firefox, qSticky, Autoheal and the socket proxy, with tmpfs
    mounts where they write (`/tmp` and `/run`; qSticky's `/app/health`). Autoheal also runs as
    `nobody` (user 65534). Not for Gluetun, which writes `/etc/resolv.conf` at start, or
    qBittorrent, whose image ignores `PUID`/`PGID` when read-only.
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
