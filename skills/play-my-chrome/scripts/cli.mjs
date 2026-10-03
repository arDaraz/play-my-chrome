import {spawn} from 'node:child_process';
import {chmodSync, closeSync, constants, openSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {chromePreflight, connectChrome} from './chrome.mjs';
import {bounded, SkillError} from './errors.mjs';
import {assertInstalled, installedPuppeteer, installPuppeteer, lockedVersion, prepareRuntime, releaseId, runtimeDirectory, withRuntimeLock} from './runtime.mjs';
import {startSession, validateRequest} from './session.mjs';
import {sendRequest, sessionStatus} from './transport.mjs';
import {assertDefaultProfile, createProfileScope, listProfiles, profileArgument, selectProfile} from './profiles.mjs';

const help = `Usage: play-my-chrome.sh <command> [arguments]
  setup                     Install locked Puppeteer, without downloading Chrome
  doctor                    Check installation, Chrome, and connection state
  profile-list              List profile names and directory IDs
  connect [--profile name]  Require a named profile; click Allow in Chrome
  ensure                    Check the existing connection
  disconnect                Disconnect Puppeteer; leave Chrome and tabs open
  tab-list                  List tabs with stable session IDs
  tab-new [url]             Create and select a tab
  tab-select <id>           Select a tab from tab-list
  tab-close                 Close only a tab created by this skill
  goto <url>                Navigate the selected tab
  snapshot                  Read the selected tab's accessibility tree
  click <selector>          Click a CSS or Puppeteer selector
  fill <selector> <text>    Fill a field
  press <key>               Press a keyboard key
  eval <expression>         Evaluate JavaScript in the selected page
  run <absolute.mjs>        Run an exported async function(page) with Puppeteer
  screenshot <absolute>     Save the selected tab's screenshot
  --version                 Print the locked Puppeteer version
Native debugging: enable chrome://inspect/#remote-debugging in Chrome 144+.
The skill never launches Chrome and needs no extension or token.`;

async function doctor(runtime) {
  const report = {puppeteer: lockedVersion(), runtime};
  try { assertInstalled(runtime); report.installation = 'ready'; }
  catch (error) { report.installation = error.message; }
  try { report.chrome = chromePreflight().version; report.debugging = 'available'; }
  catch (error) { report.chrome = error.message; report.debugging = 'unavailable'; }
  report.session = await sessionStatus(runtime);
  return report;
}

async function spawnSession(runtime, profile) {
  const logPath = join(runtime, 'daemon.log');
  const descriptor = openSync(logPath, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
  chmodSync(logPath, 0o600);
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--daemon', '--profile', profile.directory], {
    detached: true, stdio: ['ignore', descriptor, descriptor], cwd: runtime,
  });
  closeSync(descriptor);
  child.unref();
  for (let attempt = 0; attempt < 50; attempt++) {
    if ((await sessionStatus(runtime)).state !== 'missing') return;
    if (child.exitCode !== null) throw new SkillError('The session could not start. Check daemon.log with doctor.');
    await delay(100);
  }
  child.kill('SIGTERM');
  throw new SkillError('The session did not start within five seconds.', 124);
}

async function connect(runtime, selector) {
  const profile = selectProfile(selector);
  assertDefaultProfile(profile);
  await withRuntimeLock(runtime, async () => {
    const status = await sessionStatus(runtime);
    if (status.state !== 'missing') {
      if (status.release !== releaseId()) throw new SkillError('An older skill session is active. Run disconnect, then setup and connect.', 2);
      if (status.profile.directory !== profile.directory) throw new SkillError('The session uses another profile. Run disconnect before switching profiles.', 5);
      return;
    }
    assertInstalled(runtime);
    chromePreflight();
    await spawnSession(runtime, profile);
  });
  return sendRequest(runtime, {command: 'connect', args: []});
}

async function setup(runtime) {
  return withRuntimeLock(runtime, async () => {
    if ((await sessionStatus(runtime)).state !== 'missing') throw new SkillError('Disconnect the existing session before setup.', 2);
    await installPuppeteer(runtime);
    return {installation: 'ready', puppeteer: lockedVersion()};
  });
}

async function daemon(runtime, selector) {
  const profile = selectProfile(selector);
  const session = await startSession({runtime, release: releaseId(), profile,
    checkProfile: () => assertDefaultProfile(profile),
    bindProfile: browser => createProfileScope(browser, profile),
    connectBrowser: () => connectChrome(installedPuppeteer(runtime), () => {
      assertDefaultProfile(profile);
      return chromePreflight();
    }),
  });
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.once(signal, () => { void bounded(session.stop(), 2000).finally(() => process.exit(0)); });
  }
  try { await session.ready; }
  catch (error) {
    process.stderr.write('Native Chrome connection failed. Check the debugging setting and Allow dialog.\n');
    await bounded(session.stop(), 2000).finally(() => process.exit(error.exitCode ?? 1));
  }
}

async function dispatch(runtime, command, args) {
  if (command === '--daemon') return daemon(runtime, profileArgument(args));
  if (command === 'connect') return connect(runtime, profileArgument(args));
  const local = {doctor: () => doctor(runtime), setup: () => setup(runtime), 'profile-list': () => listProfiles()};
  if (Object.hasOwn(local, command)) {
    if (args.length) throw new SkillError(`${command} takes no arguments.`);
    return local[command]();
  }
  validateRequest({command, args});
  const status = await sessionStatus(runtime);
  if (command !== 'disconnect' && status.release !== releaseId()) throw new SkillError('No matching session is ready. Run connect.', 4);
  return sendRequest(runtime, {command, args});
}

async function main() {
  const [command = '--help', ...args] = process.argv.slice(2);
  if (['--help', '-h'].includes(command)) return process.stdout.write(`${help}\n`);
  if (['--version', '-v'].includes(command)) return process.stdout.write(`${lockedVersion()}\n`);
  const runtime = runtimeDirectory();
  prepareRuntime(runtime);
  const payload = await dispatch(runtime, command, args);
  process.stdout.write(`${JSON.stringify(payload ?? {completed: true}, null, 2)}\n`);
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = error.exitCode ?? 1;
});
