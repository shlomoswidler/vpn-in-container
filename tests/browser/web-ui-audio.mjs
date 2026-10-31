// The whole audio path in a real browser: the image's web UI (index.html, ui.js and
// PCMPlayer), served by a running container through tunnel.py, plays what a page in the
// container's Firefox plays (tests/e2e/audio-page.html: 1000 Hz left, 1500 Hz right, a
// click toggling it). A preload script taps every audio node the web UI connects to its
// AudioContext's destination (a splitter and one analyser per channel) and records the
// web UI's WebSockets, so the test sees what would reach the speakers.
//
// First use: before any gesture the web UI opens no audio stream and its AudioContext is
// suspended; a click on the side panel's handle leaves audio off (the volume starts at 0);
// a click on the speaker icon turns it on (saved in localStorage, the stream open, the
// context running, the volume at 90 %); a click on the remote
// page, through the VNC canvas, starts the tone, which must come out on the right channels
// at the right frequencies and volume; another click stops it (silence). Returning user,
// after a reload: no stream before a gesture, and the first click anywhere (here the
// handle) turns audio back on; the tone plays again.
//
// Reconnect, while the tone plays: the container restarts (`docker restart`, as when autoheal
// restarts it, or Gluetun with it) and the same tab, never reloaded, reconnects on its own.
// With no click in the tab, audio must come back on (the stream open, the speaker icon on) and
// the tone, started this time from inside the container (xdotool), must play again. Muted:
// after the speaker icon mutes audio, another restart and reconnect must leave it off, and
// the tone must stay silent.
//
// Prints {"total", "failed", "failures", "cases"}, or {"error"} if the run could not finish.
// Usage: node web-ui-audio.mjs chrome|firefox BINARY PROFILE_DIR PORT URL CONTAINER

import { execFile } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { promisify } from 'node:util';

import { launch, waitFor } from './browser.mjs';

const [kind, binary, profile, port, url, container] = process.argv.slice(2);
const run = promisify(execFile);
const LEFT_HZ = 1000;
const RIGHT_HZ = 1500;
// The page's tone (amplitude 0.25) at the volume the speaker icon restores (90 %).
const EXPECTED_RMS = 0.25 * 0.9 / Math.SQRT2;
const AUDIO_PATH = 'websockify-audio';

// Runs in every document before the web UI's scripts (it is passed as source text).
function tapAudio() {
    const taps = [];
    const sockets = [];
    window.__audioTaps = taps;
    window.__sockets = sockets;
    const connect = AudioNode.prototype.connect;
    AudioNode.prototype.connect = function (destination, ...rest) {
        if (destination instanceof AudioDestinationNode && !this.__tapped) {
            this.__tapped = true;
            const ctx = this.context;
            const splitter = ctx.createChannelSplitter(2);
            const mute = ctx.createGain();
            mute.gain.value = 0;
            const analysers = [0, 1].map(channel => {
                const analyser = ctx.createAnalyser();
                analyser.fftSize = 32768;
                analyser.smoothingTimeConstant = 0;
                connect.call(splitter, analyser, channel);
                connect.call(analyser, mute);
                return analyser;
            });
            connect.call(this, splitter);
            connect.call(mute, ctx.destination);
            taps.push({ ctx, analysers });
        }
        return connect.call(this, destination, ...rest);
    };
    // Returns a plain WebSocket, not a subclass: noVNC's websock.js checks for send() and
    // the rest among the channel's prototype's own properties.
    const NativeWebSocket = window.WebSocket;
    function RecordedWebSocket(...args) {
        const socket = new NativeWebSocket(...args);
        const entry = { url: String(args[0]), socket, bytes: 0 };
        sockets.push(entry);
        socket.addEventListener('message', event => {
            entry.bytes += event.data.byteLength ?? event.data.length ?? 0;
        });
        return socket;
    }
    RecordedWebSocket.prototype = NativeWebSocket.prototype;
    for (const name of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) {
        RecordedWebSocket[name] = NativeWebSocket[name];
    }
    window.WebSocket = RecordedWebSocket;
    // RMS, spectrum peak (Hz) and share of the energy at HZ (Goertzel) of each channel of
    // the newest tap.
    window.__measure = (leftHz, rightHz) => {
        const tap = taps[taps.length - 1];
        if (!tap) {
            return null;
        }
        const rate = tap.ctx.sampleRate;
        return Object.fromEntries(tap.analysers.map((analyser, i) => {
            const hz = i === 0 ? leftHz : rightHz;
            const samples = new Float32Array(analyser.fftSize);
            analyser.getFloatTimeDomainData(samples);
            const spectrum = new Float32Array(analyser.frequencyBinCount);
            analyser.getFloatFrequencyData(spectrum);
            let peak = 1;
            for (let k = 1; k < spectrum.length; k++) {
                if (spectrum[k] > spectrum[peak]) peak = k;
            }
            let energy = 0;
            for (const x of samples) energy += x * x;
            const coefficient = 2 * Math.cos(2 * Math.PI * hz / rate);
            let s1 = 0, s2 = 0;
            for (const x of samples) {
                const s0 = x + coefficient * s1 - s2;
                s2 = s1;
                s1 = s0;
            }
            const power = s1 * s1 + s2 * s2 - coefficient * s1 * s2;
            return [i === 0 ? 'left' : 'right', {
                rms: Math.sqrt(energy / samples.length),
                peakHz: peak * rate / analyser.fftSize,
                fraction: energy ? 2 * power / (samples.length * energy) : 0,
            }];
        }));
    };
}

// What the web UI's audio state is now.
const STATE = `(() => ({
    audioSockets: window.__sockets.filter(s => s.url.endsWith('/${AUDIO_PATH}'))
        .map(s => ({ url: s.url, readyState: s.socket.readyState, bytes: s.bytes })),
    contexts: window.__audioTaps.map(t => t.ctx.state),
    enabled: localStorage.getItem('audio_enabled'),
    volume: document.getElementById('noVNC_setting_audio_volume').value,
    icon: document.getElementById('noVNC_audio_button_icon').className,
}))()`;

const cases = [];
function record(name, ok, details) {
    cases.push({ name, ok: Boolean(ok), details });
}

function round(x) {
    return Math.round(x * 10000) / 10000;
}

function rounded(measured) {
    return measured && Object.fromEntries(Object.entries(measured).map(([channel, m]) => [channel, {
        rms: round(m.rms), peakHz: round(m.peakHz), fraction: round(m.fraction),
    }]));
}

function isTone(measured) {
    return Boolean(measured) && [['left', LEFT_HZ], ['right', RIGHT_HZ]].every(([channel, hz]) => {
        const m = measured[channel];
        return Math.abs(m.peakHz - hz) <= 10 && m.fraction >= 0.9 &&
            Math.abs(m.rms - EXPECTED_RMS) <= EXPECTED_RMS * 0.2;
    });
}

function isSilent(measured) {
    return Boolean(measured) && measured.left.rms < 1e-4 && measured.right.rms < 1e-4;
}

// Polls the tap until TEST(measurement) holds, for up to TIMEOUT_MS; the last measurement.
async function measureUntil(session, test, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const measured = await session.evaluate(`window.__measure(${LEFT_HZ}, ${RIGHT_HZ})`);
        if (test(measured) || Date.now() > deadline) {
            return measured;
        }
        await sleep(250);
    }
}

async function clickElement(session, selector) {
    const [x, y] = await session.evaluate(`(() => {
        const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
        return [r.left + r.width / 2, r.top + r.height / 2];
    })()`);
    await session.click(x, y);
}

async function connected(session) {
    await session.navigate(url);
    await waitFor(session, 'document.documentElement.classList.contains("noVNC_connected")',
        'the web UI connecting to the VNC server', 60000);
}

// The side panel's state: open or not, where its handle is, and whether the speaker icon
// is fully on screen.
const PANEL = `(() => {
    const handle = document.getElementById('noVNC_control_bar_handle').getBoundingClientRect();
    const icon = document.getElementById('noVNC_audio_button').getBoundingClientRect();
    return {
        open: document.getElementById('noVNC_control_bar').classList.contains('noVNC_open'),
        handleLeft: handle.left,
        iconShown: icon.width > 0 && icon.left >= 0 && icon.right <= innerWidth &&
            icon.top >= 0 && icon.bottom <= innerHeight,
    };
})()`;

// Waits until the side panel has slid fully open (the speaker icon on screen) or closed
// (the handle back at the left edge): a click during the slide misses what it aims at.
async function panelSettled(session, open) {
    const test = open ? 'p.open && p.iconShown' : '!p.open && p.handleLeft <= 1';
    await waitFor(session, `(() => { const p = ${PANEL}; return ${test}; })()`,
        `the side panel ${open ? 'opening' : 'closing'}`, 10000);
    await sleep(300);
}

// Opens or closes the side panel with a click on its handle, unless it already is so.
async function setPanel(session, open) {
    if ((await session.evaluate(PANEL)).open !== open) {
        await clickElement(session, '#noVNC_control_bar_handle');
    }
    await panelSettled(session, open);
}

const AUDIO_ON = `(() => {
    const s = ${STATE};
    return s.audioSockets.some(a => a.readyState === 1) && s.contexts.length > 0 &&
        s.contexts.every(c => c === 'running');
})()`;

function audioOn(state) {
    return state.audioSockets.some(a => a.readyState === 1) && state.contexts.length > 0 &&
        state.contexts.every(c => c === 'running') && state.icon.includes('fa-volume-up');
}

// Clicks the remote page (audio-page.html, through the VNC canvas), which toggles its tone.
async function clickRemotePage(session) {
    await clickElement(session, '#noVNC_container canvas');
}

// Runs a command in the container's X session as the app user (run.sh's in_x); its output.
async function inX(...args) {
    const { stdout } = await run('docker', ['exec', '-u', '1000', '-e', 'DISPLAY=:0', container,
        ...args]);
    return stdout.trim();
}

// The title of the container's Firefox window, or '' while there is none.
async function remoteTitle() {
    try {
        const id = (await inX('xdotool', 'search', '--classname', 'Navigator')).split('\n')[0];
        return id ? await inX('xdotool', 'getwindowname', id) : '';
    } catch {
        return '';
    }
}

// Polls the container's Firefox window title until TEST(title) holds; rejects after TIMEOUT_MS.
async function remoteTitleUntil(test, what, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const title = await remoteTitle();
        if (test(title)) {
            return title;
        }
        if (Date.now() > deadline) {
            throw new Error(`${what}: not within ${timeoutMs} ms (title "${title}")`);
        }
        await sleep(500);
    }
}

// Clicks the remote page from inside the container (xdotool, in the middle of the display),
// so that the web UI's tab gets no click: it toggles the page's tone. Resolves to whether the
// page's title then says it is playing (PLAYING true) or stopped (PLAYING false).
async function clickInContainer(playing) {
    const [width, height] = (await inX('xdotool', 'getdisplaygeometry')).split(' ').map(Number);
    await inX('xdotool', 'mousemove', String(Math.round(width / 2)),
        String(Math.round(height / 2)), 'click', '1');
    const expected = playing ? 'audio-playing state=running' : 'audio-stopped';
    return remoteTitleUntil(title => title.includes(expected), `the page ${expected}`, 10000)
        .then(() => true, () => false);
}

// Restarts the container while SESSION shows its web UI, and waits until the same tab has
// reconnected on its own and the container's Firefox shows audio-page.html again. Resolves to
// whether the tab is the same document as before (not reloaded) and connected.
async function restartContainer(session) {
    await session.evaluate('window.__beforeRestart = true');
    // Handled at once: the waits below run while the restart does.
    const restarted = run('docker', ['restart', container]).then(() => null, err => err);
    await waitFor(session, '!document.documentElement.classList.contains("noVNC_connected")',
        'the web UI losing its connection to the restarting container', 60000);
    const error = await restarted;
    if (error) {
        throw new Error(`docker restart ${container}: ${error.message}`);
    }
    await waitFor(session, 'document.documentElement.classList.contains("noVNC_connected")',
        'the web UI reconnecting after the restart', 120000);
    await remoteTitleUntil(title => title.includes('e2e audio page'),
        'the container\'s Firefox showing audio-page.html after the restart', 120000);
    return session.evaluate('window.__beforeRestart === true && ' +
        'document.documentElement.classList.contains("noVNC_connected")');
}

function mutedState(state) {
    return state.enabled === '0' && state.volume === '0' && state.icon.includes('fa-volume-mute') &&
        !state.audioSockets.some(a => a.readyState === 1);
}

// Clicks the speaker icon until audio is muted (a click toggles it), at most twice: the icon
// alone can show muted while the saved setting and the slider still say on.
async function muteWithSpeakerIcon(session) {
    await setPanel(session, true);
    for (let clicks = 0; clicks < 2; clicks++) {
        if (mutedState(await session.evaluate(STATE))) {
            break;
        }
        await clickElement(session, '#noVNC_audio_button');
        await sleep(500);
    }
    await setPanel(session, false);
}

async function main(session) {
    await session.addPreloadScript(tapAudio.toString());

    // First use.
    await connected(session);
    record('audio controls shown', await session.evaluate(
        '!document.getElementById("noVNC_audio_section").classList.contains("noVNC_hidden")'), {});
    let state = await session.evaluate(STATE);
    record('first use: no audio stream before a gesture', state.audioSockets.length === 0 &&
        state.contexts.length === 1 && state.contexts[0] === 'suspended', state);
    // The first run shows the side panel for 2 s: start from it closed.
    await panelSettled(session, false);
    // That first click (on the handle) is a gesture, but on first use the volume is 0, so
    // audio stays off until the speaker icon (or the volume slider) turns it on.
    await setPanel(session, true);
    await sleep(1000);
    state = await session.evaluate(STATE);
    record('first use: a click alone leaves audio off', state.audioSockets.length === 0 &&
        state.enabled !== '1' && state.volume === '0' && state.icon.includes('fa-volume-mute'),
        state);
    await clickElement(session, '#noVNC_audio_button');
    await waitFor(session, AUDIO_ON, 'the audio stream opening', 15000).catch(() => {});
    state = await session.evaluate(STATE);
    record('first use: the speaker icon turns audio on', state.enabled === '1' && audioOn(state),
        state);
    let measured = await measureUntil(session, isSilent, 5000);
    record('first use: silence before the page plays', isSilent(measured), rounded(measured));
    await setPanel(session, false);
    await clickRemotePage(session);
    measured = await measureUntil(session, isTone, 15000);
    state = await session.evaluate(STATE);
    record('first use: the page\'s tone plays in the browser', isTone(measured), {
        ...rounded(measured), expectedRms: round(EXPECTED_RMS),
        bytes: state.audioSockets.map(a => a.bytes),
    });
    await clickRemotePage(session);
    measured = await measureUntil(session, isSilent, 10000);
    record('first use: silence after the page stops', isSilent(measured), rounded(measured));

    // Returning user: the same profile, so localStorage keeps audio_enabled.
    await connected(session);
    state = await session.evaluate(STATE);
    record('returning: no audio stream before a gesture', state.enabled === '1' &&
        state.audioSockets.length === 0 && state.contexts.length === 1 &&
        state.contexts[0] === 'suspended', state);
    // Any first click turns it back on: here the side panel's handle (a click on the
    // canvas would also reach the remote page).
    await clickElement(session, '#noVNC_control_bar_handle');
    await waitFor(session, AUDIO_ON, 'the audio stream opening', 15000).catch(() => {});
    state = await session.evaluate(STATE);
    record('returning: the first click turns audio back on', audioOn(state), state);
    await setPanel(session, false);
    await clickRemotePage(session);
    measured = await measureUntil(session, isTone, 15000);
    record('returning: the page\'s tone plays in the browser', isTone(measured),
        rounded(measured));

    // Reconnect: the container restarts while the tone plays; no click in the tab from here on.
    record('reconnect: the same tab reconnects after the container restarts',
        await restartContainer(session), {});
    await waitFor(session, AUDIO_ON, 'the audio stream reopening', 15000).catch(() => {});
    state = await session.evaluate(STATE);
    record('reconnect: audio comes back on with no click', state.enabled === '1' &&
        audioOn(state), state);
    measured = await measureUntil(session, isSilent, 5000);
    record('reconnect: silence before the page plays again', isSilent(measured),
        rounded(measured));
    let playing = await clickInContainer(true);
    measured = await measureUntil(session, isTone, 15000);
    state = await session.evaluate(STATE);
    record('reconnect: the page\'s tone plays again with no click in the tab',
        playing && isTone(measured), {
            playing, ...rounded(measured), expectedRms: round(EXPECTED_RMS),
            bytes: state.audioSockets.map(a => a.bytes),
        });
    const stopped = await clickInContainer(false);
    measured = await measureUntil(session, isSilent, 10000);
    record('reconnect: silence after the page stops', stopped && isSilent(measured),
        { stopped, ...rounded(measured) });

    // Muted: the speaker icon turns audio off before another restart; it must stay off.
    await muteWithSpeakerIcon(session);
    state = await session.evaluate(STATE);
    record('muted: the speaker icon mutes audio before the restart', mutedState(state), state);
    record('muted: the same tab reconnects after the container restarts',
        await restartContainer(session), {});
    // As long as the reconnect case above gives audio to come back on: it must not.
    await waitFor(session, AUDIO_ON, 'the audio stream reopening', 15000).catch(() => {});
    state = await session.evaluate(STATE);
    record('muted: audio stays off after the reconnect', mutedState(state), state);
    playing = await clickInContainer(true);
    // As long as the reconnect case above waits for the tone; any sound in it fails the case.
    measured = await measureUntil(session, m => !isSilent(m), 15000);
    record('muted: the page\'s tone stays silent', playing && isSilent(measured),
        { playing, ...rounded(measured) });
    await clickInContainer(false);
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
