import {execFileSync, spawn} from 'node:child_process';
import {lstatSync} from 'node:fs';
import {homedir} from 'node:os';
import {isAbsolute, join, resolve} from 'node:path';
import {SkillError} from './errors.mjs';
import {claimDirectory} from './runtime.mjs';

export const executable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const defaultChromeDirectory = join(homedir(), 'Library/Application Support/Google/Chrome');

export function profileDirectory() {
  const profile = process.env.PLAY_MY_CHROME_PROFILE_DIR ?? join(homedir(), 'Library/Application Support/play-my-chrome/chrome-profile');
  if (!isAbsolute(profile)) throw new SkillError('The Chrome profile directory must be an absolute path.', 6);
  return resolve(profile);
}

export function prepareProfile(profile) {
  // Chrome refuses pipe debugging on its default directory, and the user's own profile must stay untouched.
  if (profile === defaultChromeDirectory || profile.startsWith(`${defaultChromeDirectory}/`)) {
    throw new SkillError('The private profile cannot be inside the normal Chrome user data directory.', 6);
  }
  claimDirectory(profile, '.play-my-chrome-profile');
}

// Login and session must share every flag that affects stored data, or the session cannot read login cookies.
export function chromeArguments(profile) {
  return [`--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check'];
}

export function profilePids(processList, profile) {
  const flag = `--user-data-dir=${profile}`;
  return processList.split('\n').flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(.+)$/);
    if (!match || !match[2].startsWith(`${executable} `)) return [];
    // ps joins arguments with spaces, and the default profile path contains one, so match the padded text.
    const args = ` ${match[2].slice(executable.length)} `;
    return args.includes(` ${flag} `) && !args.includes(' --type=') ? [match[1]] : [];
  });
}

export function assertChromeAvailable() {
  if (process.platform !== 'darwin') throw new SkillError('This skill requires macOS.', 5);
  if (!lstatSync(executable, {throwIfNoEntry: false})?.isFile()) throw new SkillError('Google Chrome is not installed in /Applications.', 5);
}

export function assertProfileIdle(profile, processList = execFileSync('/bin/ps', ['-axww', '-o', 'pid=,command='], {encoding: 'utf8', timeout: 5000})) {
  if (profilePids(processList, profile).length) {
    throw new SkillError('Another Chrome window uses the private profile. Quit that Chrome with Cmd+Q, then retry.', 5);
  }
}

export function chromePreflight(profile) {
  assertChromeAvailable();
  prepareProfile(profile);
  assertProfileIdle(profile);
}

export function launchChrome(puppeteer, profile) {
  return puppeteer.launch({
    executablePath: executable, pipe: true, ignoreDefaultArgs: true,
    args: [...chromeArguments(profile), '--headless=new', '--window-size=1440,900', 'about:blank'],
    defaultViewport: null, protocolTimeout: 15000, timeout: 30000,
    handleSIGINT: false, handleSIGTERM: false, handleSIGHUP: false,
  });
}

export function openLoginWindow(profile, url, start = spawn) {
  const child = start(executable, [...chromeArguments(profile), ...(url ? [url] : [])], {detached: true, stdio: 'ignore'});
  child.unref();
  return {state: 'login-open', pid: child.pid, profile};
}

export function loginUrl(args) {
  if (!args.length) return undefined;
  if (args.length !== 1) throw new SkillError('Use login [https-url].');
  let url;
  try { url = new URL(args[0]); }
  catch { throw new SkillError('login accepts only an absolute http or https URL.'); }
  if (!['http:', 'https:'].includes(url.protocol)) throw new SkillError('login accepts only an absolute http or https URL.');
  return url.href;
}
