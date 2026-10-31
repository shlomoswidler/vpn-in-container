// Loads a page in a headless browser (browser.mjs) and prints the text of #result once the
// page fills it in. A screenshot or --dump-dom is not enough: noVNC's browser.js has a
// top-level await (a WebCodecs probe), so its modules can finish after the load event, and
// audio-harness.html runs in real time. With CLICK_TITLE, it makes a trusted click in the
// middle of the page once the page's title is CLICK_TITLE (a user gesture, for autoplay).
// Prints {"error": ...} and exits 1 if the page does not finish within 60 s.
// Usage: node page-result.mjs chrome|firefox BINARY PROFILE_DIR PORT URL [CLICK_TITLE]

import { setTimeout as sleep } from 'node:timers/promises';

import { launch } from './browser.mjs';

const [kind, binary, profile, port, url, clickTitle] = process.argv.slice(2);
const RESULT_TIMEOUT_MS = 60000;
const POLL_MS = 200;

async function main(session) {
    await session.navigate(url);
    const deadline = Date.now() + RESULT_TIMEOUT_MS;
    let clicked = false;
    for (;;) {
        const [title, text, width, height] = await session.evaluate(
            '[document.title, document.getElementById("result")?.textContent ?? "", ' +
            'innerWidth, innerHeight]');
        if (text !== '') {
            return text;
        }
        if (clickTitle && !clicked && title === clickTitle) {
            await session.click(Math.floor(width / 2), Math.floor(height / 2));
            clicked = true;
        }
        if (Date.now() > deadline) {
            throw new Error(`#result still empty after ${RESULT_TIMEOUT_MS} ms (title "${title}")`);
        }
        await sleep(POLL_MS);
    }
}

let session;
try {
    session = await launch(kind, binary, profile, port);
    process.stdout.write(`${await main(session)}\n`);
} catch (err) {
    process.stdout.write(`${JSON.stringify({ error: err.message })}\n`);
    process.exitCode = 1;
} finally {
    await session?.close();
}
