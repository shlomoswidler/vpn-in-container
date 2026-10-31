#!/bin/sh
# Openbox binds Alt+Left drag to Move and Alt+Right drag to Resize anywhere on
# a window (the "Frame" mouse context), and Alt+Middle to Lower/Unfocus. Both
# drags grab the pointer with a 1-bit core cursor (this static Openbox build
# has no Xcursor support), and Alt+Right drag also unmaximizes Firefox. Remove
# the context so those clicks go to Firefox, and fail if an Alt+drag binding is
# left anywhere (a new image could put one in another context).
# Runs after /etc/cont-init.d/10-openbox.sh, which regenerates rc.xml on every start.

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

# OPENBOX_RC overrides the path for tests (tests/test_openbox_init.py).
RC=${OPENBOX_RC:-/var/run/openbox/rc.xml}

# Edited through a temporary file next to rc.xml rather than with sed -i, whose
# syntax differs between BusyBox/GNU sed (the image) and BSD sed (macOS, where
# the tests run).
tmp=$(mktemp "$RC.XXXXXX")
trap 'rm -f "$tmp"' EXIT
sed '/<context name="Frame">/,/<\/context>/d' "$RC" > "$tmp"
cat "$tmp" > "$RC"

if grep -q '<context name="Frame">' "$RC" || ! grep -q '<context name="Client">' "$RC"; then
    echo "could not remove the Frame mouse context from $RC" >&2
    exit 1
fi

# What matters is that no Alt+drag binding is left in any context, wherever a new image
# puts one. Openbox reads action="Drag" and each modifier without regard to case, takes
# A, Alt or Mod1 for Alt (alone or with others, as in C-A-Left), and reads the button
# attribute as a space-separated list of buttons. The check reads each <mousebind> start
# tag as one line, as the image writes them: a tag written another way fails the script
# instead of going unchecked.
binds=$(grep -c '<mousebind' "$RC" || true)
readable=$(grep -c -E '<mousebind[[:space:]][^>]*(button="[^"]*"[^>]*action="[^"]*"|action="[^"]*"[^>]*button="[^"]*")' "$RC" || true)
if [ "$binds" != "$readable" ]; then
    echo "cannot check $RC for Alt+drag bindings: a <mousebind> tag does not have its button and action on one line" >&2
    exit 1
fi
grep -n -i -E 'action="[[:space:]]*drag[[:space:]]*"' "$RC" > "$tmp" || true
alt_button='button="([^"]*[[:space:]-])?(a|alt|mod1)-'
if grep -q -i -E "$alt_button" "$tmp"; then
    echo "Openbox still has an Alt+drag binding in $RC:" >&2
    grep -i -E "$alt_button" "$tmp" >&2
    exit 1
fi
