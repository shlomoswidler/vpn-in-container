// Writes cases.js for harness.html: cursor images as noVNC would receive them,
// each with the CSS cursor value Cursor.change() is expected to produce.
//   - every file in config/cursors/native-css (keyword files and aliases):
//     the keyword the file, or its symlink target, is named for
//   - ordinary images (tests/fixtures/ordinary-cursors.mjs): a url() image cursor
//   - an empty (0x0) cursor: "none"
// Image and empty cases are interleaved with markers to check that switching
// between marker and image cursors works in both directions.
// Usage: node make-cases.mjs OUT_FILE

import { readFileSync, readdirSync, lstatSync, realpathSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { arrowCursor, lineCursors } from '../fixtures/ordinary-cursors.mjs';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '../..');
const themeCursors = join(repoRoot, 'config/cursors/native-css/cursors');

// First image of an Xcursor file, as the R, G, B, A bytes noVNC passes on.
function firstImage(path) {
    const buf = readFileSync(path);
    const pos = buf.readUInt32LE(16 + 8);
    const w = buf.readUInt32LE(pos + 16);
    const h = buf.readUInt32LE(pos + 20);
    const rgba = [];
    for (let px = 0; px < w * h; px++) {
        const argb = buf.readUInt32LE(pos + 36 + px * 4);
        rgba.push(argb >>> 16 & 0xff, argb >>> 8 & 0xff, argb & 0xff, argb >>> 24);
    }
    return { w, h, rgba };
}

const images = [arrowCursor(), ...lineCursors()].map(c => ({ ...c, expected: 'image' }));
const empty = { name: 'empty cursor', expected: 'none', w: 0, h: 0, rgba: [] };

const cases = [];
let nextImage = 0;
for (const file of readdirSync(themeCursors).sort()) {
    const path = join(themeCursors, file);
    const keyword = lstatSync(path).isSymbolicLink() ? basename(realpathSync(path)) : file;
    cases.push({ name: file, expected: keyword, ...firstImage(path) });
    if (cases.length % 10 === 1) {
        cases.push(images[nextImage++ % images.length]);
    } else if (cases.length % 10 === 5) {
        cases.push(empty);
    }
}

const [outFile] = process.argv.slice(2);
writeFileSync(outFile, `export default ${JSON.stringify(cases)};\n`);
process.stdout.write(`wrote ${cases.length} cases to ${outFile}\n`);
