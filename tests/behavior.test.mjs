import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {createConnection} from 'node:net';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {test} from 'node:test';
import {createBrowserCommands, validateCommand} from '../skills/puppeteer-my-chrome/scripts/browser.mjs';
import {chromePids, connectChrome, validateActivePort, validateChromeVersion} from '../skills/puppeteer-my-chrome/scripts/chrome.mjs';
import {bounded, SkillError} from '../skills/puppeteer-my-chrome/scripts/errors.mjs';
import {assertInstalled, assertPrivate, installPuppeteer, lockedVersion, prepareRuntime, releaseId, skillRoot, withRuntimeLock} from '../skills/puppeteer-my-chrome/scripts/runtime.mjs';
import {startSession, validateRequest} from '../skills/puppeteer-my-chrome/scripts/session.mjs';
import {requestLimit, sendRequest, sessionStatus, socketPath} from '../skills/puppeteer-my-chrome/scripts/transport.mjs';
import {assertDefaultProfile, chromeDirectory, createProfileScope, parseProfiles, profileArgument, selectProfile, verifyConnectedProfile} from '../skills/puppeteer-my-chrome/scripts/profiles.mjs';

function temporary(t) {
  const root = mkdtempSync('/tmp/pmc-test-');
  chmodSync(root, 0o700);
  t.after(() => rmSync(root, {recursive: true, force: true}));
  return root;
}

function fakePage(url = 'https://example.test/existing') {
  const page = {
    closed: false, currentUrl: url, actions: [], contextId: 'work-context',
    isClosed: () => page.closed, url: () => page.currentUrl, title: async () => 'Example',
    setDefaultTimeout: timeout => page.actions.push(['timeout', timeout]),
    setDefaultNavigationTimeout: timeout => page.actions.push(['navigation-timeout', timeout]),
    goto: async destination => { page.currentUrl = destination; page.actions.push(['goto', destination]); },
    close: async () => { page.closed = true; page.actions.push(['close']); },
    $eval: async () => join(chromeDirectory, 'Profile 1'),
    createCDPSession: async () => ({send: async () => ({targetInfo: {browserContextId: page.contextId}}), detach: async () => {}}),
    accessibility: {snapshot: async () => ({role: 'RootWebArea', name: 'Example'})},
    locator: selector => ({
      click: async () => page.actions.push(['click', selector]),
      fill: async text => page.actions.push(['fill', selector, text]),
    }),
    keyboard: {press: async key => page.actions.push(['press', key])},
    evaluate: async expression => { page.actions.push(['eval', expression]); return 'page content'; },
    screenshot: async options => { page.actions.push(['screenshot', options]); },
  };
  return page;
}

function fakeBrowser() {
  const browser = new EventEmitter();
  browser.connected = true;
  browser.defaultContextId = 'work-context';
  browser.target = () => ({createCDPSession: async () => ({send: async () => ({defaultBrowserContextId: browser.defaultContextId}), detach: async () => {}})});
  browser.original = fakePage();
  browser.tabPages = [browser.original];
  browser.pages = async () => browser.tabPages.filter(page => !page.closed);
  browser.newPage = async () => { const page = fakePage('about:blank'); browser.tabPages.push(page); return page; };
  browser.disconnectCount = 0;
  browser.disconnect = async () => { browser.connected = false; browser.disconnectCount++; browser.emit('disconnected'); };
  browser.close = () => { throw new Error('Chrome must never close'); };
  return browser;
}

async function sessionFixture(t, options = {}) {
  const runtime = temporary(t);
  const browser = fakeBrowser();
  const session = await startSession({runtime, release: 'test-release', connectBrowser: async () => browser, ...options});
  t.after(() => session.stop());
  return {runtime, browser, session};
}

function populatePackages(directory) {
  const lock = JSON.parse(readFileSync(join(directory, 'package-lock.json'), 'utf8'));
  for (const [path, entry] of Object.entries(lock.packages)) {
    if (!path) continue;
    mkdirSync(join(directory, path), {recursive: true});
    writeFileSync(join(directory, path, 'package.json'), JSON.stringify({version: entry.version}));
  }
}

function installedFixture(runtime) {
  const cli = join(runtime, 'cli');
  mkdirSync(cli, {mode: 0o700});
  cpSync(join(skillRoot, 'cli/package-lock.json'), join(cli, 'package-lock.json'));
  populatePackages(cli);
  return cli;
}

test('Chrome process parsing excludes helpers and other automation browsers', () => {
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  assert.deepEqual(chromePids(''), []);
  assert.deepEqual(chromePids(` 42 ${chrome}\n 55 ${chrome} Helper\n 60 /tmp/chrome\n`), ['42']);
  assert.deepEqual(chromePids(`42 ${chrome}\n52 ${chrome}`), ['42', '52']);
  assert.deepEqual(chromePids(`42 ${chrome} --profile-directory=Default\n52 ${chrome} --user-data-dir=/tmp/automation\n53 ${chrome} --type=renderer\n54 ${chrome} --remote-debugging-port=9222`), ['42']);
});

test('Chrome version and native endpoint boundaries fail closed', () => {
  for (const version of ['143.0.1.2', 'unknown', '144', '', '144.0.1.2junk']) assert.throws(() => validateChromeVersion(version));
  validateChromeVersion('144.0.1.2');
  validateChromeVersion('154.0.8037.95');
  for (const port of ['0', '65536', '42evil', '-1', '', '1.5']) assert.throws(() => validateActivePort(`${port}\n/devtools/browser/abc`));
  for (const path of ['https://remote.test', '/devtools/page/abc', '/devtools/browser/abc?secret=foo', '//remote.test']) assert.throws(() => validateActivePort(`9222\n${path}`));
  assert.throws(() => validateActivePort('9222\n/devtools/browser/abc\nextra'));
  validateActivePort('1\n/devtools/browser/a\n');
  validateActivePort('65535\n/devtools/browser/abc-123\n');
  validateActivePort('9222\r\n/devtools/browser\r\n');
});

test('missing or ambiguous Chrome stops before any Puppeteer call', async () => {
  let connections = 0;
  const puppeteer = {connect: async () => { connections++; }};
  for (const reason of ['missing', 'ambiguous']) {
    await assert.rejects(connectChrome(puppeteer, () => { throw new SkillError(reason, 5); }), {exitCode: 5});
  }
  assert.equal(connections, 0);
});

test('native connection uses stable discovery without a launch, extension, or credential', async () => {
  const browser = fakeBrowser();
  let connectionOptions;
  const attached = await connectChrome({connect: async options => { connectionOptions = options; return browser; }}, () => ({pids: ['42']}), () => ['42']);
  assert.equal(attached, browser);
  assert.deepEqual(connectionOptions, {channel: 'chrome', defaultViewport: null, protocolTimeout: 15000, wsOptions: {handshakeTimeout: 50000}});
  assert.equal(browser.original.actions.length, 0);
  assert.equal(browser.tabPages.length, 1);
});

test('changed Chrome or failed process inspection disconnects before any page action', async () => {
  for (const inspect of [() => ['43'], () => ['42', '43'], () => { throw new Error('ps failed'); }]) {
    const browser = fakeBrowser();
    await assert.rejects(connectChrome({connect: async () => browser}, () => ({pids: ['42']}), inspect));
    assert.equal(browser.disconnectCount, 1);
    assert.equal(browser.original.closed, false);
    assert.equal(browser.original.actions.length, 0);
  }
});

test('native connection refusal is reported without retry or fallback', async () => {
  let attempts = 0;
  await assert.rejects(connectChrome({connect: async () => { attempts++; throw new Error('Chrome refused'); }}, () => ({pids: ['42']})), /Chrome refused/);
  assert.equal(attempts, 1);
});

test('profiles expose names and IDs without account metadata and reject unknown or duplicate names', () => {
  const profiles = parseProfiles(JSON.stringify({profile: {last_used: 'Profile 1', info_cache: {
    Default: {name: 'Private', user_name: 'secret@example.test'},
    'Profile 1': {name: 'Work'}, 'Profile 2': {name: 'Work'},
    'System Profile': {name: 'System'}, '../outside': {name: 'Invalid'},
  }}}));
  assert.equal(profiles.length, 3);
  assert.equal(JSON.stringify(profiles).includes('secret'), false);
  assert.equal(selectProfile(undefined, profiles).directory, 'Profile 1');
  assert.equal(selectProfile('private', profiles).directory, 'Default');
  assert.equal(selectProfile('Profile 2', profiles).directory, 'Profile 2');
  for (const selector of ['Work', 'unknown', '../outside', '']) assert.throws(() => selectProfile(selector, profiles), {exitCode: 5});
  assert.throws(() => selectProfile(undefined, []), {exitCode: 5});
  assertDefaultProfile(profiles[1], profiles);
  assert.throws(() => assertDefaultProfile(profiles[0], profiles), {exitCode: 5});
  assert.equal(profileArgument([]), undefined);
  assert.equal(profileArgument(['--profile', 'Work']), 'Work');
  for (const args of [['Work'], ['--profile'], ['--profile', ''], ['--profile', 'Work', 'extra']]) assert.throws(() => profileArgument(args));
  for (const contents of ['null', '{}', '{"profile":{"info_cache":[]}}', 'private-account-metadata']) {
    assert.throws(() => parseProfiles(contents), error => error.exitCode === 5 && !error.message.includes('private-account-metadata'));
  }
  assert.deepEqual(parseProfiles('{"profile":{"info_cache":{"Default":null}}}'), []);
});

test('profile verification closes only its probe and rejects another profile or failed navigation', async () => {
  for (const scenario of ['match', 'mismatch', 'navigation-failure']) {
    const browser = fakeBrowser();
    const probe = fakePage();
    browser.newPage = async () => probe;
    probe.$eval = async () => join(chromeDirectory, scenario === 'match' ? 'Profile 1' : 'Default');
    if (scenario === 'navigation-failure') probe.goto = async () => { throw new Error('navigation failed'); };
    const verification = verifyConnectedProfile(browser, {directory: 'Profile 1'});
    if (scenario === 'match') await verification;
    else await assert.rejects(verification);
    assert.equal(probe.closed, true);
    assert.equal(browser.original.actions.length, 0);
    assert.equal(browser.original.closed, false);
  }
});

test('a profile mismatch after connecting disconnects before task commands', async t => {
  const browser = fakeBrowser();
  const probe = fakePage();
  probe.$eval = async () => join(chromeDirectory, 'Default');
  browser.newPage = async () => probe;
  const runtime = temporary(t);
  const session = await startSession({runtime, release: 'test-release', connectBrowser: async () => browser,
    bindProfile: connected => createProfileScope(connected, {directory: 'Profile 1'})});
  await assert.rejects(session.ready, {exitCode: 5});
  await session.stop();
  assert.equal(browser.disconnectCount, 1);
  assert.equal(probe.closed, true);
  assert.equal(browser.original.actions.length, 0);
});

test('a profile change blocks further page actions but still allows disconnect', async t => {
  let changed = false;
  const profile = {directory: 'Profile 1', name: 'Work'};
  const {runtime, browser, session} = await sessionFixture(t, {profile, checkProfile: () => {
    if (changed) throw new SkillError('profile changed', 5);
  }});
  await session.ready;
  assert.deepEqual((await sendRequest(runtime, {command: 'ensure', args: []})).profile, profile);
  changed = true;
  await assert.rejects(sendRequest(runtime, {command: 'tab-new', args: []}), {exitCode: 5});
  assert.equal(browser.tabPages.length, 1);
  await sendRequest(runtime, {command: 'disconnect', args: []});
  await session.stop();
  assert.equal(browser.original.closed, false);
});

test('native context checks exclude other profiles and stop after a default context change', async () => {
  const browser = fakeBrowser();
  const personal = fakePage('https://example.test/private');
  personal.contextId = 'private-context';
  browser.tabPages.push(personal);
  const scope = await createProfileScope(browser, {directory: 'Profile 1'});
  const commands = createBrowserCommands(browser, scope);
  const tabs = await commands('tab-list', []);
  assert.equal(tabs.length, 1);
  assert.equal(personal.actions.length, 0);
  await scope.check();
  await commands('tab-select', [tabs[0].id]);
  browser.original.contextId = 'private-context';
  await assert.rejects(commands('click', ['button']), {exitCode: 5});
  assert.equal(browser.original.actions.some(action => action[0] === 'click'), false);
  browser.defaultContextId = 'private-context';
  await assert.rejects(scope.check(), {exitCode: 5});
  browser.newPage = async () => personal;
  await assert.rejects(commands('tab-new', ['https://example.test/task']), {exitCode: 5});
  assert.equal(personal.closed, true);
  assert.equal(personal.actions.some(action => action[0] === 'goto'), false);
});

test('profile binding uses tab contexts on Chrome 144 and rejects missing or mismatched identities', async () => {
  const olderBrowser = fakeBrowser();
  olderBrowser.defaultContextId = undefined;
  const scope = await createProfileScope(olderBrowser, {directory: 'Profile 1'});
  await scope.check();
  await scope.assertPage(olderBrowser.original);
  const changedBrowser = fakeBrowser();
  changedBrowser.defaultContextId = 'another-context';
  await assert.rejects(createProfileScope(changedBrowser, {directory: 'Profile 1'}), {exitCode: 5});
  const unidentified = fakeBrowser();
  const probe = fakePage();
  probe.contextId = undefined;
  unidentified.newPage = async () => probe;
  await assert.rejects(createProfileScope(unidentified, {directory: 'Profile 1'}), {exitCode: 5});
  assert.equal(probe.closed, true);
});

test('private runtime and socket paths reject unsafe ownership types and permissions', t => {
  const root = temporary(t);
  const runtime = join(root, 'runtime');
  prepareRuntime(runtime);
  assert.equal(lstatSync(runtime).mode & 0o777, 0o700);
  chmodSync(runtime, 0o755);
  assert.throws(() => prepareRuntime(runtime), {exitCode: 6});
  const link = join(root, 'link');
  symlinkSync(runtime, link);
  assert.throws(() => prepareRuntime(link), {exitCode: 6});
  assert.throws(() => assertPrivate(runtime, 'socket'), {exitCode: 6});
  assert.throws(() => prepareRuntime(join(root, 'x'.repeat(101))), {exitCode: 6});
});

test('installation checks the lock and every transitive package before loading code', t => {
  const runtime = temporary(t);
  assert.throws(() => assertInstalled(runtime), {exitCode: 2});
  const cli = installedFixture(runtime);
  assertInstalled(runtime);
  const packagePath = join(cli, 'node_modules/puppeteer-core/package.json');
  writeFileSync(packagePath, JSON.stringify({version: '0.0.0'}));
  assert.throws(() => assertInstalled(runtime), {exitCode: 2});
  populatePackages(cli);
  rmSync(join(cli, 'node_modules/ws'), {recursive: true});
  assert.throws(() => assertInstalled(runtime), {exitCode: 2});
  populatePackages(cli);
  writeFileSync(join(cli, 'package-lock.json'), '{}');
  assert.throws(() => assertInstalled(runtime), {exitCode: 2});
  assert.equal(typeof lockedVersion(), 'string');
  assert.match(releaseId(), /^[a-f0-9]{64}$/);
});

test('failed setup preserves the previous installation and cleans staging', async t => {
  const runtime = temporary(t);
  installedFixture(runtime);
  await assert.rejects(installPuppeteer(runtime, async () => { throw new Error('npm failed'); }), /npm failed/);
  assertInstalled(runtime);
  assert.deepEqual(readdirSync(runtime), ['cli']);
  await installPuppeteer(runtime, async staging => populatePackages(staging));
  assertInstalled(runtime);
  assert.deepEqual(readdirSync(runtime), ['cli']);
});

test('setup refuses a symlinked dependency directory before npm runs', async t => {
  const runtime = temporary(t);
  const outside = temporary(t);
  symlinkSync(outside, join(runtime, 'cli'));
  let installs = 0;
  await assert.rejects(installPuppeteer(runtime, async () => { installs++; }), {exitCode: 6});
  assert.equal(installs, 0);
  assert.deepEqual(readdirSync(outside), []);
});

test('runtime lock blocks concurrent setup or connection and releases after errors', async t => {
  const runtime = temporary(t);
  let release;
  const first = withRuntimeLock(runtime, () => new Promise(resolve => { release = resolve; }));
  await assert.rejects(withRuntimeLock(runtime, async () => {}), {exitCode: 6});
  release();
  await first;
  await assert.rejects(withRuntimeLock(runtime, async () => { throw new Error('failure'); }), /failure/);
  assert.equal(existsSync(join(runtime, 'operation.lock')), false);
});

test('unknown, global-cleanup, malformed, and relative-path commands are rejected', () => {
  for (const command of ['open', 'launch', 'close-all', 'kill-all', 'attach', 'constructor', 'toString']) assert.throws(() => validateCommand(command, []));
  assert.throws(() => validateCommand('fill', ['input']));
  assert.throws(() => validateCommand('click', [42]));
  assert.throws(() => validateCommand('screenshot', ['relative.png']));
  assert.throws(() => validateCommand('run', ['relative.mjs']));
  for (const request of [null, {}, {command: 'connect', args: ['unexpected']}, {command: 'eval', args: 'bad'}]) assert.throws(() => validateRequest(request));
});

test('tab IDs are stable and page actions require an explicit selected tab', async () => {
  const browser = fakeBrowser();
  const commands = createBrowserCommands(browser);
  await assert.rejects(async () => commands('goto', ['https://example.test']), /Select an open tab/);
  const listed = await commands('tab-list', []);
  assert.equal(listed[0].id, (await commands('tab-list', []))[0].id);
  await commands('tab-select', [listed[0].id]);
  await commands('goto', ['https://example.test/selected']);
  assert.equal(browser.original.url(), 'https://example.test/selected');
  await assert.rejects(commands('tab-select', ['999']), /unavailable/);
  await commands('press', ['Enter']);
  assert.deepEqual(browser.original.actions.at(-1), ['press', 'Enter']);
  browser.original.closed = true;
  await assert.rejects(async () => commands('snapshot', []), /Select an open tab/);
});

test('closing a task tab preserves existing user tabs and creates no browser process', async () => {
  const browser = fakeBrowser();
  const commands = createBrowserCommands(browser);
  const [{id}] = await commands('tab-list', []);
  await commands('tab-select', [id]);
  await assert.rejects(commands('tab-close', []), /only closes tabs created/);
  const created = await commands('tab-new', []);
  assert.equal(created.url, 'about:blank');
  await commands('tab-close', []);
  assert.equal(browser.original.closed, false);
  assert.equal(browser.tabPages[1].closed, true);
});

test('rendered-page commands use the selected Puppeteer page and preserve Unicode', async t => {
  const runtime = temporary(t);
  const browser = fakeBrowser();
  const commands = createBrowserCommands(browser);
  await commands('tab-new', ['https://example.test/new']);
  const page = browser.tabPages[1];
  await commands('click', ['button']);
  await commands('fill', ['input', 'مرحبا']);
  await commands('press', ['Enter']);
  assert.equal(await commands('eval', ['document.title']), 'page content');
  assert.equal((await commands('snapshot', [])).tree.name, 'Example');
  const screenshot = join(runtime, 'screen.png');
  assert.deepEqual(await commands('screenshot', [screenshot]), {path: screenshot});
  assert.ok(page.actions.some(action => action[0] === 'fill' && action[2] === 'مرحبا'));
  const script = join(runtime, 'task.mjs');
  writeFileSync(script, 'export default async page => ({url: page.url()});');
  assert.equal((await commands('run', [script])).url, page.url());
  writeFileSync(script, 'export const invalid = true;');
  await assert.rejects(commands('run', [script]), /default async function/);
  assert.equal(browser.original.url(), 'https://example.test/existing');
});

test('one shared session reuses the same browser and disconnect leaves tabs open', async t => {
  let connections = 0;
  const browser = fakeBrowser();
  const {runtime, session} = await sessionFixture(t, {connectBrowser: async () => { connections++; return browser; }});
  await session.ready;
  assert.equal((await sendRequest(runtime, {command: 'connect', args: []})).state, 'ready');
  assert.equal((await sendRequest(runtime, {command: 'connect', args: []})).state, 'ready');
  await sendRequest(runtime, {command: 'tab-new', args: []});
  await sendRequest(runtime, {command: 'snapshot', args: []});
  await sendRequest(runtime, {command: 'ensure', args: []});
  assert.equal(connections, 1);
  assert.equal(lstatSync(socketPath(runtime)).mode & 0o777, 0o600);
  await sendRequest(runtime, {command: 'disconnect', args: []});
  await session.stop();
  assert.equal(browser.disconnectCount, 1);
  assert.ok(browser.tabPages.every(page => !page.closed));
  assert.equal((await sessionStatus(runtime)).state, 'missing');
});

test('the session serializes concurrent page actions', async t => {
  const {runtime, browser, session} = await sessionFixture(t);
  await session.ready;
  let inFlight = 0;
  let maximum = 0;
  browser.original.evaluate = async () => { inFlight++; maximum = Math.max(maximum, inFlight); await delay(20); inFlight--; return 'done'; };
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  await Promise.all([1, 2, 3].map(() => sendRequest(runtime, {command: 'eval', args: ['document.title']})));
  assert.equal(maximum, 1);
});

test('explicit disconnect waits for pending page actions to complete', async t => {
  const {runtime, browser, session} = await sessionFixture(t);
  await session.ready;
  const events = [];
  let release;
  let started;
  const startedPromise = new Promise(resolve => { started = resolve; });
  browser.original.evaluate = async () => {
    events.push('action-start');
    await new Promise(resolve => { release = resolve; started(); });
    events.push('action-complete');
    return 'done';
  };
  const disconnectBrowser = browser.disconnect;
  browser.disconnect = async () => { events.push('disconnect'); await disconnectBrowser(); };
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  const action = sendRequest(runtime, {command: 'eval', args: ['document.title']});
  await startedPromise;
  const disconnect = sendRequest(runtime, {command: 'disconnect', args: []});
  try {
    await delay(10);
    assert.deepEqual(events, ['action-start']);
  } finally {
    release();
    await Promise.all([action, disconnect]);
  }
  await session.stop();
  assert.deepEqual(events, ['action-start', 'action-complete', 'disconnect']);
  assert.equal(browser.original.closed, false);
});

test('a stuck page command times out even when explicit disconnect is queued', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 30});
  await session.ready;
  let started;
  const startedPromise = new Promise(resolve => { started = resolve; });
  browser.original.evaluate = () => { started(); return new Promise(() => {}); };
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  const timedOut = assert.rejects(sendRequest(runtime, {command: 'eval', args: ['document.title']}), {exitCode: 124});
  await startedPromise;
  const disconnected = sendRequest(runtime, {command: 'disconnect', args: []});
  await timedOut;
  assert.equal((await disconnected).state, 'disconnected');
  await session.stop();
  assert.equal(browser.disconnectCount, 1);
  assert.equal(browser.original.closed, false);
});

test('a queued command cannot start after its client disconnects', async t => {
  const {runtime, browser, session} = await sessionFixture(t);
  await session.ready;
  let release;
  let started;
  const startedPromise = new Promise(resolve => { started = resolve; });
  browser.original.evaluate = () => new Promise(resolve => { release = resolve; started(); });
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  const first = sendRequest(runtime, {command: 'eval', args: ['document.title']});
  await startedPromise;
  const abandoned = createConnection(socketPath(runtime));
  await new Promise(resolve => abandoned.once('connect', resolve));
  abandoned.write('{"command":"press","args":["Enter"]}\n');
  await delay(10);
  abandoned.destroy();
  await delay(10);
  release('done');
  await first;
  await sendRequest(runtime, {command: 'ensure', args: []});
  assert.equal(browser.original.actions.some(action => action[0] === 'press'), false);
});

test('profile inspection has the same deadline as a page command', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 20,
    bindProfile: async () => ({check: () => new Promise(() => {})}),
  });
  await session.ready;
  await assert.rejects(sendRequest(runtime, {command: 'ensure', args: []}), {exitCode: 124});
  await session.stop();
  assert.equal(browser.connected, false);
});

test('connection timeout removes the socket and disconnects a late browser', async t => {
  let finish;
  const browser = fakeBrowser();
  const {runtime, session} = await sessionFixture(t, {connectTimeout: 20, connectBrowser: () => new Promise(resolve => { finish = resolve; })});
  await assert.rejects(session.ready, {exitCode: 124});
  await session.stop();
  finish(browser);
  await delay(10);
  assert.equal(browser.disconnectCount, 1);
  assert.equal(existsSync(socketPath(runtime)), false);
});

test('command timeout ends the connection instead of allowing more actions', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 20});
  await session.ready;
  browser.original.evaluate = () => new Promise(() => {});
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  await assert.rejects(sendRequest(runtime, {command: 'eval', args: ['document.title']}), {exitCode: 124});
  await session.stop();
  assert.equal(browser.connected, false);
  await assert.rejects(sendRequest(runtime, {command: 'press', args: ['Enter']}), {exitCode: 4});
  assert.equal(browser.original.closed, false);
});

test('Chrome shutdown ends the session and cannot trigger an automatic reconnect', async t => {
  const {runtime, browser, session} = await sessionFixture(t);
  await session.ready;
  await browser.disconnect();
  await session.stop();
  assert.equal((await sessionStatus(runtime)).state, 'missing');
  await assert.rejects(sendRequest(runtime, {command: 'snapshot', args: []}), {exitCode: 4});
});

test('a failed browser disconnect still removes the session socket and reports failure', async t => {
  const runtime = temporary(t);
  const browser = fakeBrowser();
  browser.disconnect = async () => { throw new Error('disconnect failed'); };
  const session = await startSession({runtime, release: 'test-release', connectBrowser: async () => browser});
  await session.ready;
  await assert.rejects(session.stop(), /disconnect failed/);
  assert.equal(existsSync(socketPath(runtime)), false);
  assert.equal(browser.original.closed, false);
});

test('malformed and oversized socket requests cannot execute page actions', async t => {
  const {runtime, browser, session} = await sessionFixture(t);
  await session.ready;
  async function rawRequest(line) {
    return new Promise((resolve, reject) => {
      const socket = createConnection(socketPath(runtime));
      let reply = '';
      socket.on('connect', () => socket.end(line));
      socket.on('data', chunk => { reply += chunk; });
      socket.on('end', () => resolve(reply));
      socket.on('error', error => error.code === 'ECONNRESET' ? resolve(reply) : reject(error));
    });
  }
  assert.match(await rawRequest('not json\n'), /error/);
  assert.match(await rawRequest('{"command":"close-all","args":[]}\n'), /Unknown command/);
  assert.equal(await rawRequest('x'.repeat(requestLimit + 1)), '');
  assert.equal(browser.original.actions.filter(action => action[0] === 'goto').length, 0);
});

test('CLI help is available without setup and rejects unknown commands without browser access', t => {
  const runtime = temporary(t);
  const cli = fileURLToPath(new URL('../skills/puppeteer-my-chrome/scripts/cli.mjs', import.meta.url));
  const env = {...process.env, PUPPETEER_MY_CHROME_RUNTIME_DIR: runtime};
  const help = execFileSync(process.execPath, [cli, '--help'], {encoding: 'utf8', env});
  assert.match(help, /needs no extension or token/);
  assert.equal(execFileSync(process.execPath, [cli, '--version'], {encoding: 'utf8', env}).trim(), lockedVersion());
  assert.throws(() => execFileSync(process.execPath, [cli, 'close-all'], {env, stdio: 'pipe'}));
  assert.deepEqual(readdirSync(runtime), ['.puppeteer-my-chrome-runtime']);
});

test('deadline cleanup reports timeout and clears its timer on normal completion', async () => {
  assert.equal(await bounded(Promise.resolve('done'), 1000), 'done');
  await assert.rejects(bounded(new Promise(() => {}), 5), {exitCode: 124});
});
