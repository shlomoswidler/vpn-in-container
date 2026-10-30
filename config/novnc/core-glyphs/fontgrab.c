/*
 * fontgrab GLYPH SECONDS
 *
 * Grabs the pointer with XCreateFontCursor(GLYPH), the way Openbox sets its
 * cursors, and holds the grab for SECONDS so the cursor the VNC server sends
 * can be read. Run with XCURSOR_CORE=1: otherwise libX11 replaces the core
 * glyph with the current cursor theme's image, which Openbox (built without
 * Xcursor support) never does.
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: fontgrab GLYPH SECONDS\n");
        return 2;
    }
    char *end;
    unsigned long glyph = strtoul(argv[1], &end, 0);
    if (*end != '\0' || glyph > 255) {
        fprintf(stderr, "fontgrab: GLYPH must be a cursor font index (0-255)\n");
        return 2;
    }
    unsigned long seconds = strtoul(argv[2], &end, 0);
    if (*end != '\0') {
        fprintf(stderr, "fontgrab: SECONDS must be a number\n");
        return 2;
    }

    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        fprintf(stderr, "fontgrab: cannot open display\n");
        return 1;
    }
    Cursor cursor = XCreateFontCursor(display, (unsigned int)glyph);
    int result = XGrabPointer(display, DefaultRootWindow(display), False,
                              ButtonPressMask | PointerMotionMask, GrabModeAsync,
                              GrabModeAsync, None, cursor, CurrentTime);
    if (result != GrabSuccess) {
        fprintf(stderr, "fontgrab: pointer grab failed (%d)\n", result);
        XCloseDisplay(display);
        return 1;
    }
    XFlush(display);
    sleep((unsigned int)seconds);
    XUngrabPointer(display, CurrentTime);
    XFreeCursor(display, cursor);
    XCloseDisplay(display);
    return 0;
}
