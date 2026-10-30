// Classifies a cursor captured by rfb_cursor_probe.py using the noVNC decoder.
// Usage: node decode.mjs '<probe JSON>' <rgba file>
// Prints the decoded keyword, "transparent" for an invisible cursor, or
// "image:WxH" for an ordinary cursor image.

import { readFileSync } from 'node:fs';

import { decodeCursorKeyword } from '../../config/novnc/cursor-keyword.js';

const [probeJson, rgbaPath] = process.argv.slice(2);
const { w, h } = JSON.parse(probeJson);
const rgba = [...readFileSync(rgbaPath)];

function classify() {
    const keyword = decodeCursorKeyword(rgba, w, h);
    if (keyword !== null) {
        return keyword;
    }
    if (rgba.every((byte, i) => i % 4 !== 3 || byte === 0)) {
        return 'transparent';
    }
    return `image:${w}x${h}`;
}

process.stdout.write(`${classify()}\n`);
