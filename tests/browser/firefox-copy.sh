# shellcheck shell=bash
# Sourced by tests/browser/run.sh (and tests/browser-launch.test.mjs): the test
# Firefox runs from a copy of the Mac's Firefox.app, never from the app itself.
#
# Every Firefox that starts processes its install's pending update first
# (nsAppRunner.cpp, XREMain::XRE_mainStartup, then ProcessUpdates in
# nsUpdateDriver.cpp): when the user's own Firefox has staged one (update.status
# "applied"), each start launches updater.app to swap it in, and with the app in
# /Applications that asks the user for an administrator's password. A Firefox
# that runs also uses its install's update directory (a lock file there, and
# its update service can clean up an update it finds there). On macOS that
# directory is keyed by the app bundle's path (firefox_update_root), so a copy
# elsewhere has an update directory of its own, empty, and the user's update is
# neither applied nor touched. The copy is the same build, so the tests' Firefox
# behaves as before.

# firefox_update_root APP: the update directory Firefox uses for the app bundle
# APP (an absolute path ending in .app) on macOS: ~/Library/Caches/Mozilla/updates
# followed by APP without its leading / and its .app
# (nsXREDirProvider::GetUpdateRootDir).
firefox_update_root() {
    local path=${1#/}
    printf '%s\n' "$HOME/Library/Caches/Mozilla/updates/${path%.app}"
}

# firefox_copy APP DIR: copies the app bundle APP to DIR/Firefox.app (DIR is an
# existing directory of the caller's, removed with it) and prints the copy's
# firefox binary, with DIR's path resolved (pwd -P), the path Firefox keys the
# copy's update directory by. The copy is made of APFS clones when the volume
# allows (measured: 23 ms and about 2 MB for Firefox 159's 520 MB), else it is a
# full copy. DIR/.firefox-test-copy marks DIR for firefox_copy_cleanup.
firefox_copy() {
    local dir
    dir=$(cd "$2" && pwd -P)
    if ! cp -Rc "$1" "$dir/Firefox.app" 2>/dev/null; then
        rm -rf "$dir/Firefox.app"
        cp -R "$1" "$dir/Firefox.app"
    fi
    : >"$dir/.firefox-test-copy"
    printf '%s\n' "$dir/Firefox.app/Contents/MacOS/firefox"
}

# firefox_copy_cleanup DIR: removes the update directory Firefox made for the
# copy firefox_copy made in DIR, and the directories above it that are then
# empty, up to ~/Library/Caches/Mozilla/updates. Does nothing to a DIR
# firefox_copy did not mark, so that it cannot remove an installed app's update
# directory.
firefox_copy_cleanup() {
    local dir top root
    dir=$(cd "$1" && pwd -P) || return 0
    [[ -f "$dir/.firefox-test-copy" ]] || return 0
    top="$HOME/Library/Caches/Mozilla/updates"
    root=$(firefox_update_root "$dir/Firefox.app")
    rm -rf "$root"
    root=$(dirname "$root")
    while [[ "$root" == "$top"/* ]] && rmdir "$root" 2>/dev/null; do
        root=$(dirname "$root")
    done
}
