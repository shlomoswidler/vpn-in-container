// The web UI's warning when sound does not start (config/novnc/ui.js, checkAudioStarted):
// Firefox sometimes never starts the AudioContext even after a click that allows it, and only
// a reload brings sound back, so when sound has been turned on and the AudioContext is still
// not running AUDIO_START_MS later, the web UI says so in its status banner.
//
// The stall is made deterministic: a test-only preload replaces AudioContext.prototype.resume
// with one that never settles. For the late start (session A), at a page time the test sets
// (LATE_RESUME_MS after the speaker icon's click), the preload makes the AudioContext report
// the state "running" and fires its "statechange" event, which is what ui.js watches; the real
// context does not have to start, so the check does not depend on Firefox starting one (which
// is what sometimes fails). Two sessions run at the same time, each with its own browser and
// profile, against the same container's web UI:
//   A: a click with sound off shows no warning; then the speaker icon turns sound on, sound
//      does not start, and the warning shows within the wait; then sound "starts" late and the
//      warning goes away by itself.
//   B: sound turned off again before the wait ends shows no warning; after a reload with sound
//      muted (as B left it), a click shows no warning either.
// A recorder in the page (a MutationObserver on the status element) notes every time the
// warning shows or goes away, so nothing between two polls is missed.
//
// Prints {"total", "failed", "failures", "cases"}, or {"error"} if the run could not finish.
// Usage: node web-ui-banner.mjs chrome|firefox BINARY PROFILE_PREFIX PORT_A PORT_B URL

import { mkdirSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

import { launch, waitFor } from './browser.mjs';

const [kind, binary, profilePrefix, portA, portB, url] = process.argv.slice(2);
// ui.js's AUDIO_START_TIMEOUT and AUDIO_START_MESSAGE.
const AUDIO_START_MS = 5000;
const MESSAGE = 'Sound did not start. Reload the page, then click in it.';
// How long past AUDIO_START_MS a check waits for the warning (or for its absence), and when,
// after the speaker icon's click, session A has sound start late.
const MARGIN_MS = 1000;
const LATE_RESUME_MS = AUDIO_START_MS + 1500;

// Runs in every document before the web UI's scripts: resume() never settles; with RELEASE
// true, once the page time in window.__releaseResumeAt (set by the test) has come, every
// AudioContext reports the state "running" and fires "statechange". (RELEASE and WARNING are
// defined around it by preloadSource.)
function stubAndRecord() {
    AudioContext.prototype.resume = () => new Promise(() => {});
    if (RELEASE) {
        const nativeState = Object.getOwnPropertyDescriptor(BaseAudioContext.prototype, 'state').get;
        let released = false;
        Object.defineProperty(BaseAudioContext.prototype, 'state', {
            configurable: true,
            get() { return released ? 'running' : nativeState.call(this); },
        });
        const timer = setInterval(() => {
            if (window.__releaseResumeAt !== undefined && performance.now() >= window.__releaseResumeAt) {
                clearInterval(timer);
                released = true;
                for (const context of window.__contexts) {
                    context.dispatchEvent(new Event('statechange'));
                }
            }
        }, 20);
    }
    // The page's AudioContexts, so the test can see the player's.
    const contexts = [];
    window.__contexts = contexts;
    const NativeAudioContext = window.AudioContext;
    window.AudioContext = class extends NativeAudioContext {
        constructor(...args) {
            super(...args);
            contexts.push(this);
        }
    };
    // Every change of the warning's visibility: {t (performance.now()), shown}.
    const changes = [];
    window.__warning = changes;
    document.addEventListener('DOMContentLoaded', () => {
        const status = document.getElementById('noVNC_status');
        let shown = false;
        new MutationObserver(() => {
            const now = status.classList.contains('noVNC_open') &&
                status.classList.contains('noVNC_status_warn') &&
                status.textContent === WARNING;
            if (now !== shown) {
                shown = now;
                changes.push({ t: performance.now(), shown });
            }
        }).observe(status, { attributes: true, attributeFilter: ['class'], childList: true,
            characterData: true, subtree: true });
    });
}

// The preload's source text, with its constants filled in.
function preloadSource(release) {
    return `function () {
        const RELEASE = ${release};
        const WARNING = ${JSON.stringify(MESSAGE)};
        (${stubAndRecord.toString()})();
    }`;
}

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

// The audio state: the speaker icon, the saved setting, the newest AudioContext's state.
const AUDIO = `(() => ({
    icon: document.getElementById('noVNC_audio_button_icon').className,
    enabled: localStorage.getItem('audio_enabled'),
    context: window.__contexts.length ? window.__contexts[window.__contexts.length - 1].state : null,
}))()`;

async function clickElement(session, selector) {
    const [x, y] = await session.evaluate(`(() => {
        const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
        return [r.left + r.width / 2, r.top + r.height / 2];
    })()`);
    await session.click(x, y);
}

// Waits until the side panel has slid fully open or closed (a click during the slide misses).
async function panelSettled(session, open) {
    const test = open ? 'p.open && p.iconShown' : '!p.open && p.handleLeft <= 1';
    await waitFor(session, `(() => { const p = ${PANEL}; return ${test}; })()`,
        `the side panel ${open ? 'opening' : 'closing'}`, 10000);
    await sleep(300);
}

// Loads the web UI and waits until it is connected and the side panel (shown for 2 s on the
// first visit) is closed.
async function load(session) {
    await session.navigate(url);
    await waitFor(session, 'document.documentElement.classList.contains("noVNC_connected")',
        'the web UI connecting to the VNC server', 60000);
    await panelSettled(session, false);
}

// The page's clock now (performance.now()).
function pageNow(session) {
    return session.evaluate('performance.now()');
}

// The warning's changes since page time SINCE.
async function warningsSince(session, since) {
    return (await session.evaluate('window.__warning')).filter(c => c.t >= since);
}

// Waits until page time SINCE + MS has passed.
async function untilPageTime(session, since, ms) {
    const left = since + ms - await pageNow(session);
    if (left > 0) {
        await sleep(left);
    }
}

const cases = [];
function record(name, ok, details) {
    cases.push({ name, ok: Boolean(ok), details });
}

// A: a click with sound off; then a start that does not come in time, and comes late.
async function sessionA(session) {
    await load(session);
    let since = await pageNow(session);
    // On first use the volume is 0: the click opens the side panel and leaves sound off.
    await clickElement(session, '#noVNC_control_bar_handle');
    await untilPageTime(session, since, AUDIO_START_MS + MARGIN_MS);
    let changes = await warningsSince(session, since);
    let audio = await session.evaluate(AUDIO);
    record('warning: none after a click with sound off', changes.length === 0 &&
        audio.icon.includes('fa-volume-mute'), { changes, ...audio });

    await panelSettled(session, true);
    since = await pageNow(session);
    await clickElement(session, '#noVNC_audio_button');
    await session.evaluate(`window.__releaseResumeAt = ${since + LATE_RESUME_MS}`);
    await untilPageTime(session, since, AUDIO_START_MS + MARGIN_MS);
    changes = await warningsSince(session, since);
    audio = await session.evaluate(AUDIO);
    const shownMs = changes.length > 0 && changes[0].shown ? Math.round(changes[0].t - since) : null;
    record('warning: shown when sound does not start', shownMs !== null &&
        shownMs >= AUDIO_START_MS && shownMs <= AUDIO_START_MS + MARGIN_MS &&
        audio.icon.includes('fa-volume-up') && audio.context === 'suspended',
    { shownMs, changes, ...audio });

    await untilPageTime(session, since, LATE_RESUME_MS + MARGIN_MS);
    changes = await warningsSince(session, since);
    audio = await session.evaluate(AUDIO);
    const hiddenMs = changes.length > 1 && !changes[1].shown ? Math.round(changes[1].t - since) : null;
    record('warning: gone when sound starts late', shownMs !== null && hiddenMs !== null &&
        hiddenMs >= LATE_RESUME_MS && changes.length === 2 && audio.context === 'running' &&
        audio.icon.includes('fa-volume-up'), { shownMs, hiddenMs, changes, ...audio });
}

// B: sound turned off before the wait ends; then a reload with sound muted, and a click.
async function sessionB(session) {
    await load(session);
    await clickElement(session, '#noVNC_control_bar_handle');
    await panelSettled(session, true);
    const since = await pageNow(session);
    await clickElement(session, '#noVNC_audio_button');
    await sleep(1000);
    await clickElement(session, '#noVNC_audio_button');
    await untilPageTime(session, since, AUDIO_START_MS + MARGIN_MS);
    let changes = await warningsSince(session, since);
    let audio = await session.evaluate(AUDIO);
    record('warning: none when sound is turned off within the wait', changes.length === 0 &&
        audio.icon.includes('fa-volume-mute') && audio.enabled === '0', { changes, ...audio });

    await load(session);
    const reloaded = await pageNow(session);
    await clickElement(session, '#noVNC_control_bar_handle');
    await untilPageTime(session, reloaded, AUDIO_START_MS + MARGIN_MS);
    changes = await warningsSince(session, reloaded);
    audio = await session.evaluate(AUDIO);
    record('warning: none after a click with sound muted', changes.length === 0 &&
        audio.icon.includes('fa-volume-mute') && audio.enabled === '0', { changes, ...audio });
}

// A browser of its own (profile PROFILE_PREFIX-NAME, port PORT) with the stub; RELEASE as for
// stubAndRecord.
async function browserWithStub(name, port, release) {
    const profile = `${profilePrefix}-${name}`;
    mkdirSync(profile, { recursive: true });
    const session = await launch(kind, binary, profile, port);
    await session.addPreloadScript(preloadSource(release));
    return session;
}

const sessions = [];
try {
    // Started one after another (two Firefox started at the same moment can hang, see
    // browser.mjs), then run at the same time.
    for (const [name, port, release] of [['a', portA, true], ['b', portB, false]]) {
        sessions.push(await browserWithStub(name, port, release));
    }
    await Promise.all([sessionA(sessions[0]), sessionB(sessions[1])]);
    // In a fixed order, whichever session finished first.
    const order = [
        'warning: none after a click with sound off',
        'warning: shown when sound does not start',
        'warning: gone when sound starts late',
        'warning: none when sound is turned off within the wait',
        'warning: none after a click with sound muted',
    ];
    cases.sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name));
    const failures = cases.filter(c => !c.ok).map(c => c.name);
    process.stdout.write(`${JSON.stringify({ total: cases.length, failed: failures.length, failures, cases })}\n`);
} catch (err) {
    process.stdout.write(`${JSON.stringify({ error: err.message, cases })}\n`);
    process.exitCode = 1;
} finally {
    await Promise.all(sessions.map(session => session.close()));
}
