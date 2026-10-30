/*
 * Decodes marker cursors from the "native-css" Xcursor theme
 * (config/cursors/generate_native_theme.py in the vpn-in-container repo).
 *
 * Each cursor in that theme is a 1 pixel tall, fully opaque image:
 *   pixel 0: R,G,B = "css" (0x63, 0x73, 0x73)
 *   pixel 1: R = keyword length, G = 0, B = format version (1)
 *   pixel 2..: the CSS cursor keyword in ASCII, three characters per pixel
 *              (R, G, B), zero padded.
 * The browser can then show its own native cursor for that keyword instead
 * of an image of the remote one.
 */

const MAGIC = [0x63, 0x73, 0x73];
const FORMAT_VERSION = 1;
const HEADER_PIXELS = 2;
const CHARS_PER_PIXEL = 3;

// CSS cursor keywords the theme may name (CSS Basic User Interface Level 4).
// "auto" and "none" are excluded: the remote side never needs them.
export const NATIVE_KEYWORDS = new Set([
    'default', 'context-menu', 'help', 'pointer', 'progress', 'wait',
    'cell', 'crosshair', 'text', 'vertical-text', 'alias', 'copy', 'move',
    'no-drop', 'not-allowed', 'grab', 'grabbing', 'all-scroll',
    'col-resize', 'row-resize', 'n-resize', 'e-resize', 's-resize',
    'w-resize', 'ne-resize', 'nw-resize', 'se-resize', 'sw-resize',
    'ew-resize', 'ns-resize', 'nesw-resize', 'nwse-resize',
    'zoom-in', 'zoom-out',
]);

// Returns the CSS cursor keyword a marker cursor stands for, or null if the
// image is an ordinary cursor. rgba holds w * h pixels as R, G, B, A bytes.
export function decodeCursorKeyword(rgba, w, h) {
    if (h !== 1 || w <= HEADER_PIXELS || rgba.length !== w * 4) {
        return null;
    }
    for (let px = 0; px < w; px++) {
        if (rgba[px * 4 + 3] !== 255) {
            return null;
        }
    }
    for (let i = 0; i < MAGIC.length; i++) {
        if (rgba[i] !== MAGIC[i]) {
            return null;
        }
    }
    const length = rgba[4];
    if (rgba[5] !== 0 || rgba[6] !== FORMAT_VERSION ||
        w !== HEADER_PIXELS + Math.ceil(length / CHARS_PER_PIXEL)) {
        return null;
    }

    let keyword = '';
    for (let i = 0; i < length; i++) {
        const px = HEADER_PIXELS + Math.floor(i / CHARS_PER_PIXEL);
        keyword += String.fromCharCode(rgba[px * 4 + (i % CHARS_PER_PIXEL)]);
    }
    return NATIVE_KEYWORDS.has(keyword) ? keyword : null;
}
