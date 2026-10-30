#!/bin/sh
# Openbox binds Alt+Left drag to Move and Alt+Right drag to Resize anywhere on
# a window (the "Frame" mouse context), and Alt+Middle to Lower/Unfocus. Both
# drags grab the pointer with a 1-bit core cursor (this static Openbox build
# has no Xcursor support), and Alt+Right drag also unmaximizes Firefox. Remove
# the context so those clicks go to Firefox.
# Runs after /etc/cont-init.d/10-openbox.sh, which regenerates rc.xml on every start.

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

RC=/var/run/openbox/rc.xml

sed -i '/<context name="Frame">/,/<\/context>/d' "$RC"

if grep -q '<context name="Frame">' "$RC" || ! grep -q '<context name="Client">' "$RC"; then
    echo "could not remove the Frame mouse context from $RC" >&2
    exit 1
fi
