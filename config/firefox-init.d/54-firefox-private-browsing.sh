#!/bin/sh
# Stops the container unless FIREFOX_PRIVATE_BROWSING (in .env) is true, false or unset.
# docker-compose.yml passes it as FF_PREF_PRIVATE_BROWSING=browser.privatebrowsing.autostart=<value>,
# and the image's 56-firefox-set-prefs-from-env.sh writes <value> into prefs.js as it is.
# Firefox reads anything but true there as "off" without a word, so a typo meant to turn
# private browsing on would leave it off. Runs before that script (cont-init.d name order).

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

PREF=browser.privatebrowsing.autostart

if [ -z "${FF_PREF_PRIVATE_BROWSING+set}" ]; then
    echo "FF_PREF_PRIVATE_BROWSING is not set: docker-compose.yml must pass" \
        "$PREF=<true|false> (from FIREFOX_PRIVATE_BROWSING in .env)." >&2
    exit 1
fi

case "$FF_PREF_PRIVATE_BROWSING" in
    "$PREF="*) value=${FF_PREF_PRIVATE_BROWSING#"$PREF="} ;;
    *)
        echo "FF_PREF_PRIVATE_BROWSING is '$FF_PREF_PRIVATE_BROWSING', not $PREF=<true|false>:" \
            "docker-compose.yml must pass FIREFOX_PRIVATE_BROWSING from .env that way." >&2
        exit 1
        ;;
esac

case "$value" in
    true) echo "permanent private browsing is on (FIREFOX_PRIVATE_BROWSING=true)" ;;
    false) echo "permanent private browsing is off (FIREFOX_PRIVATE_BROWSING is false or unset)" ;;
    *)
        echo "FIREFOX_PRIVATE_BROWSING is '$value', not true or false. Set it to true or false" \
            "in .env, or leave it out (off); comments go on their own line." >&2
        exit 1
        ;;
esac
