// Ordinary (non-marker) cursor images in the R, G, B, A layout noVNC passes to
// Cursor.change(), for tests that check they are drawn as images.

// A 12x19 arrow: black fill, white outline, transparent background, the kind
// of image a classic cursor theme or a web page's custom cursor produces.
export function arrowCursor() {
    const w = 12;
    const h = 19;
    const rgba = new Array(w * h * 4).fill(0);
    const inside = (x, y) => y < 16 && x <= y * 0.7;
    for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
            if (!inside(x, y)) {
                continue;
            }
            const edge = !inside(x - 1, y) || !inside(x + 1, y) ||
                         !inside(x, y - 1) || !inside(x, y + 1);
            const value = edge ? 255 : 0;
            rgba.splice((y * w + x) * 4, 4, value, value, value, 255);
        }
    }
    return { name: 'arrow (image)', w, h, rgba };
}

// Opaque 1-pixel-tall lines: the shape closest to a marker.
export function lineCursors() {
    const line = (name, pixels) => ({
        name, w: pixels.length, h: 1, rgba: pixels.flatMap(rgb => [...rgb, 255]),
    });
    return [
        line('black line', Array(8).fill([0, 0, 0])),
        // Starts with the marker bytes "css" but has no valid header.
        line('css-prefixed line', [[0x63, 0x73, 0x73], [0, 0, 0], [0, 0, 0]]),
    ];
}
