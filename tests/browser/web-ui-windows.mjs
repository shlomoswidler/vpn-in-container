// Switching Firefox windows from the web UI: Ctrl+` typed in a real browser showing the
// image's web UI (noVNC), served by a running container through tunnel.py, must reach the
// container's Firefox and show its other window. The container runs with private-only
// browsing off, so it can have a normal and a private window, both maximized; a private
// window is opened inside the container (xdotool, Ctrl+Shift+P), so only the switch itself
// goes through the web UI. The window shown is X's active window, which must also be the top
// of Openbox's stacking order (_NET_CLIENT_LIST_STACKING).
//
// What this cannot show: whether the computer running the browser lets Ctrl+` through. On a
// Mac, macOS's own window switching is Command+`, and Control+` has no system shortcut.
//
// Prints {"total", "failed", "failures", "cases"}, or {"error"} if the run could not finish.
// Usage: node web-ui-windows.mjs chrome|firefox BINARY PROFILE_DIR PORT URL CONTAINER

import { execFile } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { promisify } from 'node:util';

import { launch, waitFor } from './browser.mjs';

const [kind, binary, profile, port, url, container] = process.argv.slice(2);
const run = promisify(execFile);
const cases = [];

function record(name, ok, details) {
    cases.push({ name, ok: Boolean(ok), details });
}

// Runs a command in the container's X session as the app user (run.sh's in_x); its output.
async function inX(...args) {
    const { stdout } = await run('docker', ['exec', '-u', '1000', '-e', 'DISPLAY=:0', container,
        ...args]);
    return stdout.trim();
}

// The container's visible Firefox windows (ids), its active window and the top of the stack.
async function windows() {
    const ids = (await inX('xdotool', 'search', '--onlyvisible', '--classname', 'Navigator'))
        .split('\n').filter(Boolean);
    const active = await inX('xdotool', 'getactivewindow');
    const stacking = await inX('obxprop', '--root', '_NET_CLIENT_LIST_STACKING');
    const top = stacking.replace(/^.*= */, '').split(',').map(id => id.trim()).pop();
    return { ids, active, top };
}

// Polls the windows until TEST holds, for up to TIMEOUT_MS; the last state.
async function windowsUntil(test, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const state = await windows();
        if (test(state) || Date.now() > deadline) {
            return state;
        }
        await sleep(250);
    }
}

async function main(session) {
    await session.navigate(url);
    await waitFor(session, 'document.documentElement.classList.contains("noVNC_connected")',
        'the web UI connecting to the VNC server', 60000);
    // A click on the remote page (blank-page.html) gives the web UI the keyboard.
    const [x, y] = await session.evaluate(`(() => {
        const r = document.querySelector('#noVNC_container canvas').getBoundingClientRect();
        return [r.left + r.width / 2, r.top + r.height / 2];
    })()`);
    await session.click(x, y);
    const first = await windowsUntil(state => state.ids.length === 1, 10000);
    const normal = first.ids[0];
    await inX('xdotool', 'key', 'ctrl+shift+p');
    const opened = await windowsUntil(state => state.ids.length === 2 &&
        state.active !== normal && state.top === state.active, 15000);
    const privateWindow = opened.ids.find(id => id !== normal);
    record('a private window opens on top', opened.ids.length === 2 &&
        opened.active === privateWindow && opened.top === privateWindow, { normal, ...opened });
    // A switch within a fraction of a second of a new window showing is lost: Firefox
    // activates the other window, but X keeps the new one active and on top (measured: lost
    // 0.2 s after the window showed, not 3 s after). A person does not switch that fast.
    await sleep(3000);
    await session.controlKey('`', 'Backquote', 192);
    let state = await windowsUntil(s => s.active === normal && s.top === normal, 10000);
    record('Ctrl+` from the web UI shows the normal window', state.ids.length === 2 &&
        state.active === normal && state.top === normal, { normal, privateWindow, ...state });
    await session.controlKey('`', 'Backquote', 192);
    state = await windowsUntil(s => s.active === privateWindow && s.top === privateWindow, 10000);
    const back = state.ids.length === 2 && state.active === privateWindow &&
        state.top === privateWindow;
    record('Ctrl+` again shows the private window', back, { normal, privateWindow, ...state });
}

let session;
try {
    session = await launch(kind, binary, profile, port);
    await main(session);
    const failures = cases.filter(c => !c.ok).map(c => c.name);
    process.stdout.write(`${JSON.stringify({ total: cases.length, failed: failures.length, failures, cases })}\n`);
} catch (err) {
    process.stdout.write(`${JSON.stringify({ error: err.message, cases })}\n`);
    process.exitCode = 1;
} finally {
    await session?.close();
}
