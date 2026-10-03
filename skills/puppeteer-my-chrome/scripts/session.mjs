import {chmodSync, lstatSync, unlinkSync} from 'node:fs';
import {createServer} from 'node:net';
import {createBrowserCommands, validateCommand} from './browser.mjs';
import {bounded, SkillError} from './errors.mjs';
import {requestLimit, socketPath} from './transport.mjs';

export function validateRequest(request) {
  if (!request || typeof request !== 'object' || !Array.isArray(request.args)) throw new SkillError('Invalid session request.');
  if (['connect', 'disconnect', 'status', 'ensure'].includes(request.command)) {
    if (request.args.length) throw new SkillError('Session commands take no arguments.');
  } else validateCommand(request.command, request.args);
}

function receiveRequest(socket, dispatch) {
  let buffer = '';
  socket.setEncoding('utf8');
  socket.setTimeout(65000, () => socket.destroy());
  socket.on('error', () => socket.destroy());
  socket.on('data', async chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > requestLimit) return socket.destroy();
    if (!buffer.includes('\n')) return;
    socket.removeAllListeners('data');
    try {
      const request = JSON.parse(buffer);
      validateRequest(request);
      socket.end(`${JSON.stringify({payload: await dispatch(request, () => !socket.destroyed)})}\n`);
    } catch (error) {
      socket.end(`${JSON.stringify({error: error.message, exitCode: error.exitCode ?? 1})}\n`);
    }
  });
}

class ChromeSession {
  state = 'connecting';
  queue = Promise.resolve();

  constructor({runtime, release, profile, checkProfile, bindProfile, connectBrowser, connectTimeout, commandTimeout}) {
    this.path = socketPath(runtime);
    this.release = release;
    this.profile = profile;
    this.checkProfile = checkProfile;
    this.bindProfile = bindProfile;
    this.connectBrowser = connectBrowser;
    this.connectTimeout = connectTimeout;
    this.commandTimeout = commandTimeout;
    this.server = createServer(socket => receiveRequest(socket, (request, isActive) => this.dispatch(request, isActive)));
  }

  async listen() {
    await new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.path, resolve);
    });
    chmodSync(this.path, 0o600);
    this.socketIdentity = lstatSync(this.path);
    this.ready = bounded(this.attach(), this.connectTimeout);
    this.ready.catch(() => this.stopInBackground());
  }

  async attach() {
    this.browser = await this.connectBrowser();
    if (this.state === 'disconnected') { await this.browser.disconnect(); return; }
    this.browser.on('disconnected', () => this.stopInBackground());
    this.profileScope = await this.bindProfile?.(this.browser);
    if (this.state === 'disconnected') { await this.detachBrowser(); return; }
    this.commands = createBrowserCommands(this.browser, this.profileScope);
    this.state = 'ready';
  }

  detachBrowser() {
    this.detaching ??= Promise.resolve().then(async () => {
      if (this.browser?.connected) await this.browser.disconnect();
    });
    return this.detaching;
  }

  stop() {
    this.state = 'disconnected';
    this.stopping ??= Promise.resolve().then(async () => {
      try {
        await this.detachBrowser();
      } finally {
        if (lstatSync(this.path, {throwIfNoEntry: false})?.ino === this.socketIdentity.ino) unlinkSync(this.path);
        await new Promise(resolve => this.server.close(resolve));
      }
    });
    return this.stopping;
  }

  stopInBackground() {
    void this.stop().catch(() => {
      process.stderr.write('Session cleanup failed. Inspect Chrome before reconnecting.\n');
    });
  }

  async execute(request) {
    if (request.command === 'disconnect') {
      try { await this.detachBrowser(); }
      finally { this.stopInBackground(); }
      return {state: 'disconnected'};
    }
    await this.ready;
    if (this.state !== 'ready' || !this.browser.connected) throw new SkillError('The Chrome session disconnected. Run connect.', 4);
    try {
      return await bounded(this.executeCommand(request), this.commandTimeout);
    } catch (error) {
      if (error.exitCode === 124) this.stopInBackground();
      throw error;
    }
  }

  async executeCommand(request) {
    this.checkProfile?.();
    await this.profileScope?.check();
    if (['connect', 'ensure'].includes(request.command)) return this.status();
    return this.commands(request.command, request.args);
  }

  dispatch(request, isActive) {
    if (request.command === 'status') return Promise.resolve(this.status());
    if (request.command === 'disconnect') return this.execute(request);
    const pending = this.queue.then(() => {
      if (!isActive()) throw new SkillError('The request ended before its command started.', 4);
      return this.execute(request);
    });
    // Each request returns its own error; the queue must remain available for later requests.
    this.queue = pending.catch(() => {});
    return pending;
  }

  status() { return {state: this.state, release: this.release, profile: this.profile}; }
}

export async function startSession({connectTimeout = 60000, commandTimeout = 45000, ...options}) {
  const session = new ChromeSession({...options, connectTimeout, commandTimeout});
  await session.listen();
  return {stop: () => session.stop(), ready: session.ready};
}
