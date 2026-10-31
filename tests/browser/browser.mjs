// Drives a headless browser for the tests in this directory: Chrome over the Chrome
// DevTools Protocol (CDP), Firefox over WebDriver BiDi. Both run in real time, each with
// the throwaway profile it is given.
//
// launch(kind, binary, profile, port) resolves to a session with:
//   navigate(url)            loads URL and waits for its load event
//   evaluate(expression)     the value of a JavaScript expression in the page (JSON-able)
//   click(x, y)              a trusted left click at (x, y) in CSS pixels: it counts as a
//                            user gesture (user activation) for the autoplay policy
//   addPreloadScript(source) runs SOURCE (a function's source text) in every new document
//                            before the page's own scripts
//   close()                  ends the session and stops the browser
//
// Chrome runs muted (--mute-audio) and with its desktop autoplay policy set explicitly
// (--autoplay-policy=document-user-activation-required), so headless mode cannot differ.
// Firefox uses its default autoplay policy; it is muted through media.volume_scale, which
// scales only what reaches the speakers.

import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const CONNECT_TIMEOUT_MS = 30000;
const POLL_MS = 200;

function connectWebSocket(url) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(url);
        ws.onopen = () => resolve(ws);
        ws.onerror = () => reject(new Error(`cannot connect to ${url}`));
    });
}

// Retries CONNECT until it resolves, for up to CONNECT_TIMEOUT_MS.
async function retry(what, connect) {
    const deadline = Date.now() + CONNECT_TIMEOUT_MS;
    for (;;) {
        try {
            return await connect();
        } catch (err) {
            if (Date.now() > deadline) {
                throw new Error(`${what}: ${err.message}`);
            }
            await sleep(POLL_MS);
        }
    }
}

// JSON commands over WS with numeric ids; ERROR_OF(message) is the error text of a failed
// reply, or undefined.
function commandClient(ws, errorOf) {
    let nextId = 1;
    const pending = new Map();
    ws.onmessage = ({ data }) => {
        const message = JSON.parse(data);
        const handler = pending.get(message.id);
        if (!handler) {
            return;
        }
        pending.delete(message.id);
        const error = errorOf(message);
        if (error) {
            handler.reject(new Error(error));
        } else {
            handler.resolve(message.result);
        }
    };
    return (method, params = {}) => new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
    });
}

async function launchChrome(binary, profile, port) {
    const browser = spawn(binary, [
        '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, '--mute-audio',
        '--autoplay-policy=document-user-activation-required', 'about:blank',
    ], { stdio: 'ignore' });
    try {
        const wsUrl = await retry(`no DevTools page target on port ${port}`, async () => {
            const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
            const page = targets.find(target => target.type === 'page');
            if (!page) {
                throw new Error('no page yet');
            }
            return page.webSocketDebuggerUrl;
        });
        const ws = await connectWebSocket(wsUrl);
        const send = commandClient(ws, m => m.error && `${m.error.code}: ${m.error.message}`);
        let loaded = null;
        const onEvent = ws.onmessage;
        ws.onmessage = event => {
            const message = JSON.parse(event.data);
            if (message.method === 'Page.loadEventFired' && loaded) {
                loaded();
                loaded = null;
            }
            onEvent(event);
        };
        await send('Page.enable');
        const evaluate = async expression => {
            const { result, exceptionDetails } = await send('Runtime.evaluate', {
                expression, returnByValue: true, awaitPromise: true,
            });
            if (exceptionDetails) {
                throw new Error(`${expression}: ${exceptionDetails.exception?.description ?? exceptionDetails.text}`);
            }
            return result.value;
        };
        return {
            async navigate(url) {
                const done = new Promise(resolve => { loaded = resolve; });
                await send('Page.navigate', { url });
                await done;
            },
            evaluate,
            async click(x, y) {
                const point = { x, y, button: 'left', clickCount: 1 };
                await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none' });
                await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...point });
                await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...point });
            },
            async addPreloadScript(source) {
                await send('Page.addScriptToEvaluateOnNewDocument', { source: `(${source})();` });
            },
            async close() {
                ws.close();
                browser.kill();
            },
        };
    } catch (err) {
        browser.kill();
        throw err;
    }
}

async function launchFirefox(binary, profile, port) {
    writeFileSync(join(profile, 'user.js'), 'user_pref("media.volume_scale", "0.0");\n');
    const browser = spawn(binary, [
        '--headless', '--no-remote', '--profile', profile,
        '--remote-debugging-port', String(port), 'about:blank',
    ], { stdio: 'ignore' });
    try {
        const ws = await retry(`no WebDriver BiDi endpoint on port ${port}`,
            () => connectWebSocket(`ws://127.0.0.1:${port}/session`));
        const send = commandClient(ws, m => m.type === 'error' && `${m.error}: ${m.message}`);
        await send('session.new', { capabilities: {} });
        const { contexts } = await send('browsingContext.getTree');
        const context = contexts[0].context;
        const evaluate = async expression => {
            // BiDi returns values as typed remote values; JSON keeps them plain.
            const reply = await send('script.evaluate', {
                expression: `(async () => JSON.stringify(await (${expression})))()`,
                target: { context },
                awaitPromise: true,
            });
            if (reply.type === 'exception') {
                throw new Error(`${expression}: ${reply.exceptionDetails.text}`);
            }
            return reply.result.value === undefined ? undefined : JSON.parse(reply.result.value);
        };
        return {
            async navigate(url) {
                await send('browsingContext.navigate', { context, url, wait: 'complete' });
            },
            evaluate,
            async click(x, y) {
                await send('input.performActions', {
                    context,
                    actions: [{
                        type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' },
                        actions: [
                            { type: 'pointerMove', x: Math.round(x), y: Math.round(y) },
                            { type: 'pointerDown', button: 0 },
                            { type: 'pointerUp', button: 0 },
                        ],
                    }],
                });
            },
            async addPreloadScript(source) {
                await send('script.addPreloadScript', { functionDeclaration: source });
            },
            async close() {
                await send('session.end').catch(() => {});
                ws.close();
                browser.kill();
            },
        };
    } catch (err) {
        browser.kill();
        throw err;
    }
}

export function launch(kind, binary, profile, port) {
    if (kind === 'chrome') {
        return launchChrome(binary, profile, port);
    }
    if (kind === 'firefox') {
        return launchFirefox(binary, profile, port);
    }
    throw new Error(`unknown browser ${kind}: chrome or firefox`);
}

// Polls EXPRESSION in SESSION until it is truthy; resolves to its value, or rejects with
// WHAT after TIMEOUT_MS.
export async function waitFor(session, expression, what, timeoutMs = 30000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const value = await session.evaluate(expression);
        if (value) {
            return value;
        }
        if (Date.now() > deadline) {
            throw new Error(`${what}: not within ${timeoutMs} ms`);
        }
        await sleep(POLL_MS);
    }
}
