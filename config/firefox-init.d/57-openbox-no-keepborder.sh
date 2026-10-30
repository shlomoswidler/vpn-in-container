#!/bin/sh
# Openbox keeps a 1px top border on the maximized, undecorated Firefox window
# when <keepBorder> is yes. That strip shows the root window's cursor, which
# this static Openbox build (no Xcursor support) sets to the 1-bit core arrow.
# Disable keepBorder so Firefox covers the whole screen.
# Runs after /etc/cont-init.d/10-openbox.sh, which regenerates rc.xml on every start.

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

RC=/var/run/openbox/rc.xml

sed -i 's|<keepBorder>yes</keepBorder>|<keepBorder>no</keepBorder>|' "$RC"

if ! grep -q '<keepBorder>no</keepBorder>' "$RC"; then
    echo "keepBorder is not disabled in $RC" >&2
    exit 1
fi
