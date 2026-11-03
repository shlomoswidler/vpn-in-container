// Tests for how tests/browser launches its browsers: that they can reach only loopback
// (browser.mjs's CLOSED_PROXY). Run: node --test tests/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { connect } from 'node:net';
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
