import assert from 'node:assert/strict';
import {execFile, execFileSync} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {createConnection} from 'node:net';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {test} from 'node:test';
import {promisify} from 'node:util';
import {createBrowserCommands, validateCommand} from '../skills/play-my-chrome/scripts/browser.mjs';
import {assertProfileIdle, chromeArguments, executable, launchChrome, loginUrl, openLoginWindow, prepareProfile, profilePids} from '../skills/play-my-chrome/scripts/chrome.mjs';
import {bounded} from '../skills/play-my-chrome/scripts/errors.mjs';
import {assertInstalled, assertPrivate, installPuppeteer, lockedVersion, prepareRuntime, releaseId, skillRoot, withRuntimeLock} from '../skills/play-my-chrome/scripts/runtime.mjs';
import {startSession, validateRequest} from '../skills/play-my-chrome/scripts/session.mjs';
import {requestLimit, sendRequest, sessionStatus, socketPath} from '../skills/play-my-chrome/scripts/transport.mjs';

function temporary(t) {
  const root = mkdtempSync('/tmp/pmc-test-');
  chmodSync(root, 0o700);
  t.after(() => rmSync(root, {recursive: true, force: true}));
  return root;
}

function fakePage(url = 'https://example.test/existing') {
  const page = {
    closed: false, currentUrl: url, actions: [],
    isClosed: () => page.closed, url: () => page.currentUrl, title: async () => 'Example',
    setDefaultTimeout: timeout => page.actions.push(['timeout', timeout]),
    setDefaultNavigationTimeout: timeout => page.actions.push(['navigation-timeout', timeout]),
    goto: async destination => { page.currentUrl = destination; page.actions.push(['goto', destination]); },
    close: async () => { page.closed = true; page.actions.push(['close']); },
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
  browser.original = fakePage();
  browser.tabPages = [browser.original];
  browser.pages = async () => browser.tabPages.filter(page => !page.closed);
  browser.newPage = async () => { const page = fakePage('about:blank'); browser.tabPages.push(page); return page; };
  browser.closeCount = 0;
  browser.exit = () => { browser.connected = false; browser.emit('disconnected'); };
  browser.close = async () => { browser.closeCount++; browser.exit(); };
  browser.disconnect = () => { throw new Error('A launched Chrome must close, not detach'); };
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

test('Chrome launches on the private profile over a pipe with no default automation flags', async () => {
  const browser = fakeBrowser();
  let options;
  const launched = await launchChrome({launch: async launchOptions => { options = launchOptions; return browser; }}, '/tmp/pmc profile');
  assert.equal(launched, browser);
  assert.equal(options.executablePath, executable);
  assert.equal(options.pipe, true);
  assert.equal(options.ignoreDefaultArgs, true);
  assert.deepEqual(options.args.slice(0, 3), chromeArguments('/tmp/pmc profile'));
  assert.ok(options.args.includes('--headless=new'));
  assert.equal(options.args.some(arg => /remote-debugging-port|enable-automation|use-mock-keychain|password-store/.test(arg)), false);
  assert.equal(options.handleSIGTERM, false);
});

test('the login window shares the session profile flags and has no debugging channel', () => {
  let call;
  const result = openLoginWindow('/tmp/pmc profile', 'https://example.test/sign-in', (...args) => {
    call = args;
    return {pid: 42, unref: () => { call.push('unref'); }};
  });
  assert.deepEqual(result, {state: 'login-open', pid: 42, profile: '/tmp/pmc profile'});
  assert.equal(call[0], executable);
  assert.deepEqual(call[1], [...chromeArguments('/tmp/pmc profile'), 'https://example.test/sign-in']);
  assert.equal(call[1].some(arg => arg.includes('remote-debugging') || arg.includes('headless')), false);
  assert.deepEqual(call[2], {detached: true, stdio: 'ignore'});
  assert.equal(call.at(-1), 'unref');
  assert.equal(loginUrl([]), undefined);
  assert.equal(loginUrl(['https://example.test']), 'https://example.test/');
  for (const args of [['file:///etc/passwd'], ['javascript:alert(1)'], ['example.test'], ['https://a.test', 'extra']]) assert.throws(() => loginUrl(args));
});

test('a Chrome process on the private profile blocks launch and login', () => {
  const profile = '/tmp/pmc profile';
  const main = `42 ${executable} --user-data-dir=${profile} --no-first-run`;
  assert.deepEqual(profilePids(main, profile), ['42']);
  assert.deepEqual(profilePids(`${main}\n43 ${executable} --type=renderer --user-data-dir=${profile}`, profile), ['42']);
  assert.deepEqual(profilePids(`44 ${executable}\n45 ${executable} --user-data-dir=/tmp/other\n46 /tmp/chrome --user-data-dir=${profile}`, profile), []);
  assert.deepEqual(profilePids(`47 ${executable} --user-data-dir=${profile}`, profile), ['47']);
  assert.throws(() => assertProfileIdle(profile, main), {exitCode: 5});
  assertProfileIdle(profile, `44 ${executable}`);
});

test('the private profile directory is claimed, private, and never the normal Chrome directory', t => {
  const root = temporary(t);
  const profile = join(root, 'profile');
  prepareProfile(profile);
  prepareProfile(profile);
  assert.equal(lstatSync(profile).mode & 0o777, 0o700);
  assert.deepEqual(readdirSync(profile), ['.play-my-chrome-profile']);
  const unrelated = join(root, 'unrelated');
  mkdirSync(unrelated, {mode: 0o700});
  writeFileSync(join(unrelated, 'Local State'), '{}');
  assert.throws(() => prepareProfile(unrelated), {exitCode: 6});
  const link = join(root, 'link');
  symlinkSync(profile, link);
  assert.throws(() => prepareProfile(link), {exitCode: 6});
  const chromeDirectory = join(homedir(), 'Library/Application Support/Google/Chrome');
  for (const path of [chromeDirectory, join(chromeDirectory, 'Default')]) assert.throws(() => prepareProfile(path), {exitCode: 6});
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

test('tab-close closes only a tab created during this connection', async () => {
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

test('one shared session reuses the same browser and disconnect closes it', async t => {
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
  assert.equal(browser.closeCount, 1);
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
  const closeBrowser = browser.close;
  browser.close = async () => { events.push('close'); await closeBrowser(); };
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
  assert.deepEqual(events, ['action-start', 'action-complete', 'close']);
});

test('a stuck page command times out even when explicit disconnect is queued', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 30, stuckTimeout: 60});
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
  assert.equal(browser.closeCount, 1);
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

test('connection timeout removes the socket and closes a late browser', async t => {
  let finish;
  const browser = fakeBrowser();
  const {runtime, session} = await sessionFixture(t, {connectTimeout: 20, connectBrowser: () => new Promise(resolve => { finish = resolve; })});
  await assert.rejects(session.ready, {exitCode: 124});
  await session.stop();
  finish(browser);
  await delay(10);
  assert.equal(browser.closeCount, 1);
  assert.equal(existsSync(socketPath(runtime)), false);
});

test('a command timeout keeps the connection and holds later commands until the slow command finishes', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 20});
  await session.ready;
  const events = [];
  let finish;
  browser.original.evaluate = () => new Promise(resolve => {
    events.push('slow-start');
    finish = () => { events.push('slow-end'); resolve('late'); };
  });
  browser.original.keyboard.press = async () => { events.push('press'); };
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  await assert.rejects(sendRequest(runtime, {command: 'eval', args: ['document.title']}), {exitCode: 124, message: /connection stays open/});
  const press = sendRequest(runtime, {command: 'press', args: ['Enter']});
  await delay(30);
  assert.deepEqual(events, ['slow-start']);
  finish();
  await press;
  assert.deepEqual(events, ['slow-start', 'slow-end', 'press']);
  assert.equal(browser.connected, true);
  assert.equal(browser.closeCount, 0);
  assert.equal((await sendRequest(runtime, {command: 'ensure', args: []})).state, 'ready');
});

test('Chrome shutdown releases commands queued behind a timed-out command', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 20});
  await session.ready;
  browser.original.evaluate = () => new Promise(() => {});
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  await assert.rejects(sendRequest(runtime, {command: 'eval', args: ['document.title']}), {exitCode: 124});
  const press = assert.rejects(sendRequest(runtime, {command: 'press', args: ['Enter']}), {exitCode: 4});
  await delay(10);
  browser.exit();
  await press;
  await session.stop();
});

test('a command stuck past the hard limit ends the connection and blocks further actions', async t => {
  const {runtime, browser, session} = await sessionFixture(t, {commandTimeout: 20, stuckTimeout: 60});
  await session.ready;
  browser.original.evaluate = () => new Promise(() => {});
  const [{id}] = await sendRequest(runtime, {command: 'tab-list', args: []});
  await sendRequest(runtime, {command: 'tab-select', args: [id]});
  await assert.rejects(sendRequest(runtime, {command: 'eval', args: ['document.title']}), {exitCode: 124});
  await assert.rejects(sendRequest(runtime, {command: 'press', args: ['Enter']}), {exitCode: 4});
  assert.equal(browser.connected, false);
  assert.equal(browser.closeCount, 1);
});

test('Chrome shutdown ends the session and cannot trigger an automatic reconnect', async t => {
  const {runtime, browser, session} = await sessionFixture(t);
  await session.ready;
  browser.exit();
  await session.stop();
  assert.equal((await sessionStatus(runtime)).state, 'missing');
  await assert.rejects(sendRequest(runtime, {command: 'snapshot', args: []}), {exitCode: 4});
});

test('a failed browser close still removes the session socket and reports failure', async t => {
  const runtime = temporary(t);
  const browser = fakeBrowser();
  browser.close = async () => { throw new Error('close failed'); };
  const session = await startSession({runtime, release: 'test-release', connectBrowser: async () => browser});
  await session.ready;
  await assert.rejects(session.stop(), /close failed/);
  assert.equal(existsSync(socketPath(runtime)), false);
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
  const cli = fileURLToPath(new URL('../skills/play-my-chrome/scripts/cli.mjs', import.meta.url));
  const env = {...process.env, PLAY_MY_CHROME_RUNTIME_DIR: runtime, PLAY_MY_CHROME_PROFILE_DIR: join(runtime, 'profile')};
  const help = execFileSync(process.execPath, [cli, '--help'], {encoding: 'utf8', env});
  assert.match(help, /needs no extension or token/);
  assert.equal(execFileSync(process.execPath, [cli, '--version'], {encoding: 'utf8', env}).trim(), lockedVersion());
  assert.throws(() => execFileSync(process.execPath, [cli, 'close-all'], {env, stdio: 'pipe'}));
  assert.deepEqual(readdirSync(runtime), ['.play-my-chrome-runtime']);
});

test('login refuses while a session holds the private profile', async t => {
  const runtime = join(temporary(t), 'runtime');
  prepareRuntime(runtime);
  const session = await startSession({runtime, release: 'test-release', connectBrowser: async () => fakeBrowser()});
  t.after(() => session.stop());
  await session.ready;
  const cli = fileURLToPath(new URL('../skills/play-my-chrome/scripts/cli.mjs', import.meta.url));
  const profile = join(runtime, '..', 'profile');
  const env = {...process.env, PLAY_MY_CHROME_RUNTIME_DIR: runtime, PLAY_MY_CHROME_PROFILE_DIR: profile};
  await assert.rejects(promisify(execFile)(process.execPath, [cli, 'login'], {env}), error => error.code === 2 && /Run disconnect before login/.test(error.stderr));
  assert.equal(existsSync(profile), false);
});

test('deadline cleanup reports timeout and clears its timer on normal completion', async () => {
  assert.equal(await bounded(Promise.resolve('done'), 1000), 'done');
  await assert.rejects(bounded(new Promise(() => {}), 5), {exitCode: 124});
});
