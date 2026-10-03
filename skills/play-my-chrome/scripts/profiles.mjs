import {lstatSync, readFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {SkillError} from './errors.mjs';

export const chromeDirectory = join(homedir(), 'Library/Application Support/Google/Chrome');

export function parseProfiles(contents) {
  let profile;
  try { profile = JSON.parse(contents)?.profile; }
  catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    throw new SkillError('Chrome profile metadata is incomplete. Wait for Chrome to finish writing, then retry.', 5);
  }
  if (!profile?.info_cache || typeof profile.info_cache !== 'object' || Array.isArray(profile.info_cache)) {
    throw new SkillError('Chrome profile names are unavailable.', 5);
  }
  return Object.entries(profile.info_cache).filter(([directory, details]) =>
    /^(?:Default|Profile \d+)$/.test(directory) && typeof details?.name === 'string'
  ).map(([directory, details]) => ({directory, name: details.name, default: directory === (profile.last_used || 'Default')}));
}

export function listProfiles() {
  const path = join(chromeDirectory, 'Local State');
  const stat = lstatSync(path, {throwIfNoEntry: false});
  if (!stat?.isFile() || stat.uid !== process.getuid()) throw new SkillError('Chrome profile metadata is unavailable or unsafe.', 5);
  return parseProfiles(readFileSync(path, 'utf8'));
}

export function selectProfile(selector, profiles = listProfiles()) {
  if (selector === undefined) {
    const selected = profiles.find(profile => profile.default);
    if (!selected) throw new SkillError('Chrome has no available default profile.', 5);
    return selected;
  }
  const exact = profiles.find(profile => profile.directory === selector);
  const matches = exact ? [exact] : profiles.filter(profile => profile.name.toLowerCase() === selector.toLowerCase());
  if (matches.length !== 1) throw new SkillError('The profile name is unknown or ambiguous. Run profile-list and use its directory ID.', 5);
  return matches[0];
}

export function assertDefaultProfile(selected, profiles = listProfiles()) {
  if (!profiles.some(profile => profile.directory === selected.directory && profile.default)) {
    throw new SkillError(`Chrome selected another profile. Select "${selected.name}" in Chrome, then disconnect and connect --profile "${selected.directory}".`, 5);
  }
}

export async function verifyConnectedProfile(browser, selected) {
  const probe = await browser.newPage();
  try {
    await probe.goto('chrome://version', {waitUntil: 'domcontentloaded', timeout: 15000});
    const path = await probe.$eval('#profile_path', element => element.textContent.trim());
    if (path !== join(chromeDirectory, selected.directory)) {
      throw new SkillError('Chrome connected to another profile. No task page command was attempted.', 5);
    }
    return await pageContextId(probe);
  } finally {
    await probe.close();
  }
}

async function pageContextId(page) {
  const session = await page.createCDPSession();
  try { return (await session.send('Target.getTargetInfo')).targetInfo.browserContextId; }
  finally { await session.detach(); }
}

export async function createProfileScope(browser, selected) {
  const session = await browser.target().createCDPSession();
  const currentContext = async () => (await session.send('Target.getBrowserContexts')).defaultBrowserContextId;
  const contextId = await verifyConnectedProfile(browser, selected);
  if (!contextId) throw new SkillError('Chrome did not identify the connected profile. No task page command was attempted.', 5);
  async function check() {
    const current = await currentContext();
    if (current !== undefined && current !== contextId) throw new SkillError('Chrome changed its default profile. Disconnect before choosing another profile.', 5);
  }
  await check();
  const includes = async page => await pageContextId(page) === contextId;
  return {
    includes,
    check,
    async assertPage(page) {
      if (!await includes(page)) throw new SkillError('The tab belongs to another Chrome profile. No task page command was attempted.', 5);
    },
  };
}

export function profileArgument(args) {
  if (!args.length) return undefined;
  if (args.length !== 2 || args[0] !== '--profile' || !args[1].trim()) {
    throw new SkillError('Use connect [--profile <name-or-directory>].');
  }
  return args[1];
}
