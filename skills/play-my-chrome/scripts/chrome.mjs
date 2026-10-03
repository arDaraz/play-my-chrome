import {execFileSync} from 'node:child_process';
import {lstatSync, readFileSync} from 'node:fs';
import {join} from 'node:path';
import {SkillError} from './errors.mjs';
import {chromeDirectory} from './profiles.mjs';

const executable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const debuggingHelp = 'In Chrome 144 or newer, enable chrome://inspect/#remote-debugging, then run connect and click Allow in Chrome.';

export function chromePids(processList) {
  return processList.split('\n').flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(.+)$/);
    if (!match || (match[2] !== executable && !match[2].startsWith(`${executable} `))) return [];
    const args = match[2].slice(executable.length);
    if (args && !args.trimStart().startsWith('--')) return [];
    return /(?:^|\s)--(?:user-data-dir|type|remote-debugging-port|remote-debugging-pipe)(?:=|\s|$)/.test(args) ? [] : [match[1]];
  }).sort();
}

export function runningChrome() {
  if (process.platform !== 'darwin') throw new SkillError('This skill requires macOS.', 5);
  const pids = chromePids(execFileSync('/bin/ps', ['-axo', 'pid=,command='], {encoding: 'utf8', timeout: 5000}));
  if (pids.length !== 1) throw new SkillError('Open exactly one normal Google Chrome instance before connecting.', 5);
  return pids;
}

export function validateChromeVersion(version) {
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(version) || Number(version.split('.')[0]) < 144) {
    throw new SkillError('Google Chrome 144 or newer is required.', 5);
  }
}

export function validateActivePort(contents) {
  const [port, browserPath, ...extra] = contents.split('\n').map(line => line.trim()).filter(Boolean);
  if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535 ||
      !/^\/devtools\/browser(?:\/[a-zA-Z0-9-]+)?$/.test(browserPath) || extra.length) {
    throw new SkillError(`Chrome's native debugging endpoint is invalid. ${debuggingHelp}`, 5);
  }
}

export function chromePreflight() {
  const pids = runningChrome();
  const version = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', '/Applications/Google Chrome.app/Contents/Info.plist'], {encoding: 'utf8', timeout: 5000}).trim();
  validateChromeVersion(version);
  const portFile = join(chromeDirectory, 'DevToolsActivePort');
  const portStat = lstatSync(portFile, {throwIfNoEntry: false});
  if (!portStat?.isFile() || portStat.uid !== process.getuid()) {
    throw new SkillError(`Chrome's native debugging is unavailable. ${debuggingHelp}`, 5);
  }
  validateActivePort(readFileSync(portFile, 'utf8'));
  return {pids, version};
}

export async function connectChrome(puppeteer, preflight = chromePreflight, inspectPids = runningChrome) {
  const before = preflight();
  const browser = await puppeteer.connect({channel: 'chrome', defaultViewport: null, protocolTimeout: 15000, wsOptions: {handshakeTimeout: 50000}});
  try {
    if (inspectPids().join(',') !== before.pids.join(',')) {
      throw new SkillError('Chrome changed during connection. No page command was attempted. Run connect again.', 5);
    }
    return browser;
  } catch (error) {
    await browser.disconnect();
    throw error;
  }
}
