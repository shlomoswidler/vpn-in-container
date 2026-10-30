// Tests for config/novnc/cursor-keyword.js. Run: node --test tests/
//
// The theme tests read the committed config/cursors/native-css theme, parse
// each Xcursor file the way libXcursor stores it (ARGB, little-endian), turn
// it into the R, G, B, A bytes noVNC hands to Cursor.change(), and check the
// decoder recovers the keyword the file (or its symlink target) is named for.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, lstatSync, realpathSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { decodeCursorKeyword, NATIVE_KEYWORDS } from '../config/novnc/cursor-keyword.js';
import { arrowCursor, lineCursors } from './fixtures/ordinary-cursors.mjs';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const themeCursors = join(repoRoot, 'config/cursors/native-css/cursors');

// Independent encoder for the marker format, used to build edge cases.
function marker(keyword, { magic = [0x63, 0x73, 0x73], length = keyword.length,
                           version = 1, alpha = 255 } = {}) {
    const chars = [...keyword].map(c => c.charCodeAt(0));
    const w = 2 + Math.ceil(length / 3);
    const rgba = new Array(w * 4).fill(0);
    rgba.splice(0, 3, ...magic);
    rgba[4] = length;
    rgba[6] = version;
    chars.forEach((code, i) => {
        rgba[(2 + Math.floor(i / 3)) * 4 + (i % 3)] = code;
    });
    for (let px = 0; px < w; px++) {
        rgba[px * 4 + 3] = alpha;
    }
    return { rgba, w, h: 1 };
}

// Parses an Xcursor file and returns its images as noVNC RGBA arrays.
function readXcursor(path) {
    const buf = readFileSync(path);
    assert.equal(buf.toString('latin1', 0, 4), 'Xcur', `${path}: magic`);
    const ntoc = buf.readUInt32LE(12);
    const images = [];
    for (let i = 0; i < ntoc; i++) {
        const entry = 16 + i * 12;
        if (buf.readUInt32LE(entry) !== 0xfffd0002) {
            continue;
        }
        const pos = buf.readUInt32LE(entry + 8);
        const w = buf.readUInt32LE(pos + 16);
        const h = buf.readUInt32LE(pos + 20);
        const rgba = [];
        for (let px = 0; px < w * h; px++) {
            const argb = buf.readUInt32LE(pos + 36 + px * 4);
            rgba.push(argb >>> 16 & 0xff, argb >>> 8 & 0xff, argb & 0xff, argb >>> 24);
        }
        images.push({ rgba, w, h, nominal: buf.readUInt32LE(entry + 4) });
    }
    return images;
}

test('decodes every keyword in the allow list', () => {
    for (const keyword of NATIVE_KEYWORDS) {
        const { rgba, w, h } = marker(keyword);
        assert.equal(decodeCursorKeyword(rgba, w, h), keyword);
    }
});

test('rejects images that are not markers', () => {
    const cases = {
        'wrong magic': marker('default', { magic: [0x63, 0x73, 0x74] }),
        'wrong version': marker('default', { version: 2 }),
        'translucent pixel': marker('default', { alpha: 254 }),
        'length longer than image': marker('default', { length: 9 }),
        'keyword not allowed': marker('url'),
        'auto is not allowed': marker('auto'),
    };
    for (const [name, { rgba, w, h }] of Object.entries(cases)) {
        assert.equal(decodeCursorKeyword(rgba, w, h), null, name);
    }
});

test('rejects marker bytes in the wrong shape', () => {
    const { rgba, w } = marker('pointer');
    assert.equal(decodeCursorKeyword(rgba, w, 2), null, 'height 2');
    assert.equal(decodeCursorKeyword(rgba.slice(0, -4), w, 1), null, 'short buffer');
    assert.equal(decodeCursorKeyword(rgba.slice(0, 8), 2, 1), null, 'header only');
    assert.equal(decodeCursorKeyword([], 0, 0), null, 'empty');
});

test('ordinary cursor images are not mistaken for markers', () => {
    for (const { name, rgba, w, h } of [arrowCursor(), ...lineCursors()]) {
        assert.equal(decodeCursorKeyword(rgba, w, h), null, name);
    }
});

test('every cursor in the native-css theme decodes to its keyword', () => {
    const files = readdirSync(themeCursors);
    const keywords = new Set();
    for (const file of files) {
        const path = join(themeCursors, file);
        const target = lstatSync(path).isSymbolicLink() ? basename(realpathSync(path)) : file;
        assert.ok(NATIVE_KEYWORDS.has(target), `${file} -> ${target} is a keyword file`);
        const images = readXcursor(path);
        assert.equal(images.length, 1, `${file}: one image`);
        const { rgba, w, h } = images[0];
        assert.equal(decodeCursorKeyword(rgba, w, h), target, file);
        keywords.add(target);
    }
    assert.deepEqual([...keywords].sort(), [...NATIVE_KEYWORDS].sort(),
                     'theme has one file per allowed keyword');
});
