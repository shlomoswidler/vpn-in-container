// Tests for how tests/browser launches its browsers: that they can reach only loopback
// (browser.mjs's CLOSED_PROXY), and that Firefox runs from a copy of the app, with an
// update directory of its own (firefox-copy.sh). Run: node --test tests/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
    chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync,
} from 'node:fs';
import { connect } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CLOSED_PROXY, chromeArgs, firefoxUserJs } from './browser/browser.mjs';

const browserDir = join(dirname(fileURLToPath(import.meta.url)), 'browser');
const proxyArg = `--proxy-server=${CLOSED_PROXY.host}:${CLOSED_PROXY.port}`;

// The prefs a user.js sets, as { name: value }.
function userPrefs(userJs) {
    const prefs = {};
    for (const line of userJs.trim().split('\n')) {
        const match = /^user_pref\((".*?"), (.*)\);$/.exec(line);
        assert.ok(match, `not a user_pref line: ${line}`);
        prefs[JSON.parse(match[1])] = JSON.parse(match[2]);
    }
    return prefs;
}

test('the closed proxy is on loopback', () => {
    assert.equal(CLOSED_PROXY.host, '127.0.0.1');
});

test('nothing listens at the closed proxy', async () => {
    const error = await new Promise(resolve => {
        const socket = connect(CLOSED_PROXY.port, CLOSED_PROXY.host);
        socket.on('connect', () => {
            socket.destroy();
            resolve(null);
        });
        socket.on('error', resolve);
    });
    assert.equal(error?.code, 'ECONNREFUSED');
});

test('Chrome driven by browser.mjs uses the closed proxy, with no bypass list', () => {
    const args = chromeArgs('/profile', 9222);
    assert.ok(args.includes(proxyArg), args.join(' '));
    assert.ok(!args.some(arg => arg.startsWith('--proxy-bypass-list')), args.join(' '));
    assert.ok(!args.some(arg => arg.includes('direct')), args.join(' '));
});

test('Chrome driven by browser.mjs makes no background requests and runs no updater', () => {
    const args = chromeArgs('/profile', 9222);
    assert.ok(args.includes('--disable-background-networking'), args.join(' '));
    assert.ok(args.includes('--disable-component-update'), args.join(' '));
});

test('every Chrome that run.sh starts itself uses the closed proxy, with no background requests', () => {
    const script = readFileSync(join(browserDir, 'run.sh'), 'utf8');
    // Each command that starts Chrome headless, with its continuation lines.
    const commands = script.split(/(?<!\\)\n/).filter(command => command.includes('--headless'));
    assert.ok(commands.length > 0, 'run.sh starts no headless Chrome');
    for (const command of commands) {
        assert.ok(command.includes(proxyArg), command);
        assert.ok(command.includes('--disable-background-networking'), command);
        assert.ok(command.includes('--disable-component-update'), command);
    }
});

test("Firefox's profile sends everything but loopback to the closed proxy", () => {
    const prefs = userPrefs(firefoxUserJs());
    assert.equal(prefs['network.proxy.type'], 1);
    for (const scheme of ['http', 'ssl']) {
        assert.equal(prefs[`network.proxy.${scheme}`], CLOSED_PROXY.host);
        assert.equal(prefs[`network.proxy.${scheme}_port`], CLOSED_PROXY.port);
    }
    assert.equal(prefs['network.proxy.failover_direct'], false);
    assert.equal(prefs['network.proxy.allow_bypass'], false);
    assert.equal(prefs['network.dns.disabled'], true);
    assert.equal(prefs['network.proxy.allow_hijacking_localhost'], false);
    assert.equal(prefs['network.dns.disablePrefetch'], true);
    assert.equal(prefs['media.volume_scale'], '0.0');
});

// Runs SCRIPT in bash after sourcing firefox-copy.sh, with HOME set to HOME_DIR (so that
// nothing here touches the real ~/Library); ARGS are $1.... Returns stdout, trimmed;
// fails the test if bash fails.
function withFirefoxCopy(homeDir, script, ...args) {
    const result = spawnSync('bash', [
        '-euo', 'pipefail', '-c', `source "$0"\n${script}`, join(browserDir, 'firefox-copy.sh'),
        ...args,
    ], { env: { ...process.env, HOME: homeDir }, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
}

// A temporary directory with a home directory and a stand-in Firefox.app (in
// ROOT/Applications) in it, removed after the test.
function fakeInstall(t) {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'firefox-copy-test-')));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const app = join(root, 'Applications', 'Firefox.app');
    mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true });
    mkdirSync(join(app, 'Contents', 'Resources'), { recursive: true });
    writeFileSync(join(app, 'Contents', 'Info.plist'), '<plist>159.0</plist>\n');
    writeFileSync(join(app, 'Contents', 'Resources', 'application.ini'), 'Version=159.0\n');
    writeFileSync(join(app, 'Contents', 'MacOS', 'firefox'), '#!/bin/sh\necho stand-in\n');
    chmodSync(join(app, 'Contents', 'MacOS', 'firefox'), 0o755);
    const home = join(root, 'home');
    const work = join(root, 'work');
    mkdirSync(home);
    mkdirSync(work);
    return { root, app, home, work };
}

test("Firefox's update directory is keyed by the app bundle's path, as on macOS", () => {
    const home = '/nonexistent-home';
    assert.equal(withFirefoxCopy(home, 'firefox_update_root "$1"', '/Applications/Firefox.app'),
        `${home}/Library/Caches/Mozilla/updates/Applications/Firefox`);
    assert.equal(withFirefoxCopy(home, 'firefox_update_root "$1"', '/private/var/T/tmp.x/Firefox.app'),
        `${home}/Library/Caches/Mozilla/updates/private/var/T/tmp.x/Firefox`);
});

test('firefox_copy runs Firefox from a copy of the app, with an update directory of its own', t => {
    const { app, home, work } = fakeInstall(t);
    const binary = withFirefoxCopy(home, 'firefox_copy "$1" "$2"', app, work);
    const copy = join(work, 'Firefox.app');
    assert.equal(binary, join(copy, 'Contents', 'MacOS', 'firefox'));
    assert.ok(!binary.startsWith(app), binary);
    for (const file of ['Info.plist', 'MacOS/firefox', 'Resources/application.ini']) {
        assert.equal(readFileSync(join(copy, 'Contents', file), 'utf8'),
            readFileSync(join(app, 'Contents', file), 'utf8'), file);
    }
    assert.equal(spawnSync(binary, { encoding: 'utf8' }).stdout, 'stand-in\n');
    const roots = withFirefoxCopy(home,
        'firefox_update_root "$1"; firefox_update_root "${2%/Contents/MacOS/firefox}"',
        app, binary).split('\n');
    assert.equal(roots.length, 2);
    assert.notEqual(roots[0], roots[1]);
});

test("firefox_copy resolves the copy's directory, the path Firefox keys its update directory by", t => {
    const { root, app, home, work } = fakeInstall(t);
    // A symbolic link to WORK: the copy's binary is under WORK's real path.
    const link = join(root, 'link');
    spawnSync('ln', ['-s', work, link]);
    const binary = withFirefoxCopy(home, 'firefox_copy "$1" "$2"', app, link);
    assert.equal(binary, join(work, 'Firefox.app', 'Contents', 'MacOS', 'firefox'));
});

test("firefox_copy_cleanup removes only the copy's update directory", t => {
    const { root, app, home, work } = fakeInstall(t);
    const updates = join(home, 'Library', 'Caches', 'Mozilla', 'updates');
    // The installed app's staged update, and what Firefox made for the copy.
    const staged = join(updates, ...app.slice(1, -'.app'.length).split('/'), 'updates', '0');
    mkdirSync(staged, { recursive: true });
    writeFileSync(join(staged, 'update.status'), 'applied\n');
    const binary = withFirefoxCopy(home, 'firefox_copy "$1" "$2"', app, work);
    const copyRoot = withFirefoxCopy(home, 'firefox_update_root "${1%/Contents/MacOS/firefox}"',
        binary);
    mkdirSync(join(copyRoot, 'updates', '0'), { recursive: true });
    writeFileSync(join(copyRoot, '.parentlock'), '');

    withFirefoxCopy(home, 'firefox_copy_cleanup "$1"', work);
    assert.ok(!existsSync(copyRoot), copyRoot);
    // The empty directories above the copy's are gone too, up to the updates directory.
    assert.ok(!existsSync(join(updates, ...work.slice(1).split('/'))));
    assert.equal(readFileSync(join(staged, 'update.status'), 'utf8'), 'applied\n');
    assert.ok(existsSync(updates));
    assert.ok(existsSync(join(work, 'Firefox.app')), 'the copy itself is the caller\'s to remove');

    // A directory firefox_copy did not mark is left alone, even an installed app's.
    withFirefoxCopy(home, 'firefox_copy_cleanup "$1"', join(root, 'Applications'));
    assert.equal(readFileSync(join(staged, 'update.status'), 'utf8'), 'applied\n');
});

test('run.sh starts Firefox only from firefox_copy\'s copy of the app', () => {
    const script = readFileSync(join(browserDir, 'run.sh'), 'utf8');
    const assignments = [...script.matchAll(/^\s*FIREFOX=(.*)$/gm)].map(match => match[1]);
    assert.deepEqual(assignments, ['""', '$(firefox_copy "$FIREFOX_APP" "$WORK")']);
    assert.ok(script.includes('firefox_copy_cleanup "$WORK"'));
    // The app's own binary is only checked for, never run.
    const uses = script.split('\n').filter(line => line.includes('$FIREFOX_APP/Contents/MacOS'));
    assert.deepEqual(uses.map(line => line.trim()),
        ['[[ -x "$FIREFOX_APP/Contents/MacOS/firefox" ]] || continue']);
});
