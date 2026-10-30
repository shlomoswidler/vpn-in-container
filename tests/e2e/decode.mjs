// Classifies a cursor captured by rfb_cursor_probe.py using the noVNC decoder.
// Usage: node decode.mjs '<probe JSON>' <rgba file>
// Prints the keyword of a native-css marker, "glyph:<keyword>" for one of
// Openbox's core glyphs, "transparent" for an invisible cursor, or
// "image:WxH" for an ordinary cursor image.

import { readFileSync } from 'node:fs';

import { coreGlyphKeyword, decodeCursorKeyword } from '../../config/novnc/cursor-keyword.js';

const [probeJson, rgbaPath] = process.argv.slice(2);
const { w, h, hotx, hoty } = JSON.parse(probeJson);
const rgba = [...readFileSync(rgbaPath)];

function classify() {
    const keyword = decodeCursorKeyword(rgba, w, h);
    if (keyword !== null) {
        return keyword;
    }
    const glyphKeyword = coreGlyphKeyword(rgba, hotx, hoty, w, h);
    if (glyphKeyword !== null) {
        return `glyph:${glyphKeyword}`;
    }
    if (rgba.every((byte, i) => i % 4 !== 3 || byte === 0)) {
        return 'transparent';
    }
    return `image:${w}x${h}`;
}

process.stdout.write(`${classify()}\n`);
