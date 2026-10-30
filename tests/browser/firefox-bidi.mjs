// Loads a page in headless Firefox through WebDriver BiDi and prints the text
// of #result once the page fills it in. A screenshot is not enough because
// noVNC's browser.js has a top-level await (a WebCodecs probe), so its
// modules can finish after the load event.
// Usage: node firefox-bidi.mjs FIREFOX_BINARY PROFILE_DIR PORT URL

import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';

const [firefox, profile, port, url] = process.argv.slice(2);
const RESULT_TIMEOUT_MS = 30000;
const CONNECT_TIMEOUT_MS = 30000;
const POLL_MS = 200;

const browser = spawn(firefox, [
    '--headless', '--no-remote', '--profile', profile,
    '--remote-debugging-port', port, 'about:blank',
], { stdio: 'ignore' });

async function connect() {
    const deadline = Date.now() + CONNECT_TIMEOUT_MS;
    for (;;) {
        try {
            return await new Promise((resolve, reject) => {
                const ws = new WebSocket(`ws://127.0.0.1:${port}/session`);
                ws.onopen = () => resolve(ws);
                ws.onerror = () => reject(new Error('connection failed'));
            });
        } catch (err) {
            if (Date.now() > deadline) {
                throw new Error(`no WebDriver BiDi endpoint on port ${port}: ${err.message}`);
            }
            await sleep(POLL_MS);
        }
    }
}

function client(ws) {
    let nextId = 1;
    const pending = new Map();
    ws.onmessage = ({ data }) => {
        const message = JSON.parse(data);
        const handler = pending.get(message.id);
        if (!handler) {
            return;
        }
        pending.delete(message.id);
        if (message.type === 'error') {
            handler.reject(new Error(`${message.error}: ${message.message}`));
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

async function main() {
    const ws = await connect();
    const send = client(ws);
    try {
        await send('session.new', { capabilities: {} });
        const { contexts } = await send('browsingContext.getTree');
        const context = contexts[0].context;
        await send('browsingContext.navigate', { context, url, wait: 'complete' });
        const deadline = Date.now() + RESULT_TIMEOUT_MS;
        for (;;) {
            const { result } = await send('script.evaluate', {
                expression: 'document.getElementById("result").textContent',
                target: { context },
                awaitPromise: false,
            });
            if (result.type === 'string' && result.value !== '') {
                process.stdout.write(`${result.value}\n`);
                return;
            }
            if (Date.now() > deadline) {
                throw new Error(`#result still empty after ${RESULT_TIMEOUT_MS} ms`);
            }
            await sleep(POLL_MS);
        }
    } finally {
        await send('session.end').catch(() => {});
        ws.close();
    }
}

try {
    await main();
} catch (err) {
    process.stdout.write(`${JSON.stringify({ error: err.message })}\n`);
    process.exitCode = 1;
} finally {
    browser.kill();
}
