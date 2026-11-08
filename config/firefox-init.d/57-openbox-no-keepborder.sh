#!/bin/sh
# Openbox keeps a 1px top border on the maximized, undecorated Firefox window
# when <keepBorder> is yes. That strip shows the root window's cursor, which
# this static Openbox build (no Xcursor support) sets to the 1-bit core arrow.
# Disable keepBorder so Firefox covers the whole screen.
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
sed 's|<keepBorder>yes</keepBorder>|<keepBorder>no</keepBorder>|' "$RC" >"$tmp"
cat "$tmp" >"$RC"

if ! grep -q '<keepBorder>no</keepBorder>' "$RC"; then
    echo "keepBorder is not disabled in $RC" >&2
    exit 1
fi
