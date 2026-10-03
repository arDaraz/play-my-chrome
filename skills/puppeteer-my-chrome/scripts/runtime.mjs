import {execFile} from 'node:child_process';
import {createHash} from 'node:crypto';
import {chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {homedir} from 'node:os';
import {dirname, isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {SkillError} from './errors.mjs';

export const skillRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const shippedCli = join(skillRoot, 'cli');

export function runtimeDirectory() {
  const runtime = process.env.PUPPETEER_MY_CHROME_RUNTIME_DIR ?? join(homedir(), 'Library/Caches/puppeteer-my-chrome');
  if (!isAbsolute(runtime)) throw new SkillError('The runtime directory must be an absolute path.', 6);
  return resolve(runtime);
}

export function assertPrivate(path, kind) {
  const stat = lstatSync(path, {throwIfNoEntry: false});
  const matchesKind = kind === 'directory' ? stat?.isDirectory() : stat?.isSocket();
  const permissions = kind === 'directory' ? 0o700 : 0o600;
  if (!matchesKind || stat.uid !== process.getuid() || (stat.mode & 0o777) !== permissions) {
    throw new SkillError(`Unsafe ${kind}: ${path}. Expected an owned, private, non-symlink ${kind}.`, 6);
  }
}

export function prepareRuntime(runtime) {
  if (!existsSync(dirname(runtime))) mkdirSync(dirname(runtime), {recursive: true});
  if (!lstatSync(runtime, {throwIfNoEntry: false})) mkdirSync(runtime, {mode: 0o700});
  assertPrivate(runtime, 'directory');
  if (Buffer.byteLength(join(runtime, 'session.sock')) > 100) {
    throw new SkillError('The runtime path is too long for a local socket. Set PUPPETEER_MY_CHROME_RUNTIME_DIR to a shorter private absolute path.', 6);
  }
  claimRuntime(runtime);
}

function claimRuntime(runtime) {
  const marker = join(runtime, '.puppeteer-my-chrome-runtime');
  const claim = 'puppeteer-my-chrome\n';
  const stat = lstatSync(marker, {throwIfNoEntry: false});
  if (!stat) {
    if (readdirSync(runtime).length) throw new SkillError('The runtime directory contains unrelated files. Choose a dedicated empty directory.', 6);
    writeFileSync(marker, claim, {mode: 0o600, flag: 'wx'});
    return;
  }
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 || readFileSync(marker, 'utf8') !== claim) {
    throw new SkillError('The runtime ownership marker is unsafe or belongs to another tool.', 6);
  }
}

export function releaseId() {
  const hash = createHash('sha256').update(readFileSync(join(shippedCli, 'package-lock.json')));
  for (const name of readdirSync(join(skillRoot, 'scripts')).sort()) {
    hash.update(readFileSync(join(skillRoot, 'scripts', name)));
  }
  return hash.digest('hex');
}

export function lockedVersion() {
  return JSON.parse(readFileSync(join(shippedCli, 'package-lock.json'), 'utf8')).packages['node_modules/puppeteer-core'].version;
}

export function assertInstalled(runtime) {
  const cli = join(runtime, 'cli');
  if (!lstatSync(cli, {throwIfNoEntry: false})) throw new SkillError('Puppeteer is missing. Run setup.', 2);
  assertDependencyTree(cli);
}

function assertDependencyTree(cli) {
  assertPrivate(cli, 'directory');
  const lockPath = join(cli, 'package-lock.json');
  if (!existsSync(lockPath) || !readFileSync(lockPath).equals(readFileSync(join(shippedCli, 'package-lock.json')))) {
    throw new SkillError('Puppeteer needs setup for this skill release.', 2);
  }
  const lock = JSON.parse(readFileSync(lockPath, 'utf8'));
  for (const [packagePath, entry] of Object.entries(lock.packages)) {
    if (!packagePath) continue;
    const manifest = join(cli, packagePath, 'package.json');
    if (!existsSync(manifest) || JSON.parse(readFileSync(manifest, 'utf8')).version !== entry.version) {
      throw new SkillError('A locked Puppeteer dependency is missing or has changed. Run setup.', 2);
    }
  }
}

export function installedPuppeteer(runtime) {
  assertInstalled(runtime);
  return createRequire(join(runtime, 'cli/package.json'))('puppeteer-core').default;
}

async function installLockedPackages(staging) {
  await promisify(execFile)(join(dirname(process.execPath), 'npm'), ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], {
    cwd: staging, timeout: 600000, env: {...process.env, PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`},
  });
}

function replaceInstallation(staging, installedCli) {
  const previous = `${staging}.previous`;
  if (existsSync(installedCli)) renameSync(installedCli, previous);
  try {
    renameSync(staging, installedCli);
  } catch (error) {
    if (existsSync(previous)) renameSync(previous, installedCli);
    throw error;
  }
  rmSync(previous, {recursive: true, force: true});
}

export async function installPuppeteer(runtime, install = installLockedPackages) {
  const installedCli = join(runtime, 'cli');
  if (lstatSync(installedCli, {throwIfNoEntry: false})) assertPrivate(installedCli, 'directory');
  const staging = mkdtempSync(join(runtime, '.setup-'));
  chmodSync(staging, 0o700);
  try {
    cpSync(join(shippedCli, 'package.json'), join(staging, 'package.json'));
    cpSync(join(shippedCli, 'package-lock.json'), join(staging, 'package-lock.json'));
    await install(staging);
    assertDependencyTree(staging);
    replaceInstallation(staging, installedCli);
    assertInstalled(runtime);
  } finally {
    rmSync(staging, {recursive: true, force: true});
  }
}

export async function withRuntimeLock(runtime, operation) {
  const lock = join(runtime, 'operation.lock');
  try {
    mkdirSync(lock, {mode: 0o700});
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    throw new SkillError('Another setup or connection is in progress. Retry when it finishes. If interrupted, inspect operation.lock before removing it.', 6);
  }
  try {
    writeFileSync(join(lock, 'pid'), String(process.pid), {mode: 0o600, flag: 'wx'});
    return await operation();
  } finally {
    rmSync(lock, {recursive: true});
  }
}
