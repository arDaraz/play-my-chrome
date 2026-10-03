import {chmodSync, lstatSync, unlinkSync} from 'node:fs';
import {createServer} from 'node:net';
import {createBrowserCommands, validateCommand} from './browser.mjs';
import {bounded, SkillError} from './errors.mjs';
import {commandTimeout as defaultCommandTimeout, requestLimit, requestTimeout, socketPath, stuckTimeout as defaultStuckTimeout} from './transport.mjs';

export function validateRequest(request) {
  if (!request || typeof request !== 'object' || !Array.isArray(request.args)) throw new SkillError('Invalid session request.');
  if (['connect', 'disconnect', 'status', 'ensure'].includes(request.command)) {
    if (request.args.length) throw new SkillError('Session commands take no arguments.');
  } else validateCommand(request.command, request.args);
}

function receiveRequest(socket, dispatch) {
  let buffer = '';
  socket.setEncoding('utf8');
  socket.setTimeout(requestTimeout, () => socket.destroy());
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

  constructor({runtime, release, profile, checkProfile, bindProfile, connectBrowser, connectTimeout, commandTimeout, stuckTimeout}) {
    this.path = socketPath(runtime);
    this.release = release;
    this.profile = profile;
    this.checkProfile = checkProfile;
    this.bindProfile = bindProfile;
    this.connectBrowser = connectBrowser;
    this.connectTimeout = connectTimeout;
    this.commandTimeout = commandTimeout;
    this.stuckTimeout = stuckTimeout;
    this.timeoutMessage = `The command exceeded ${commandTimeout / 1000} seconds. The connection stays open; the next command waits until this one finishes.`;
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
    this.endStuckWait?.();
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

  async start(request) {
    if (request.command === 'disconnect') return {running: this.disconnect()};
    await this.ready;
    if (this.state !== 'ready' || !this.browser.connected) throw new SkillError('The Chrome session disconnected. Run connect.', 4);
    return {running: this.executeCommand(request)};
  }

  async disconnect() {
    try { await this.detachBrowser(); }
    finally { this.stopInBackground(); }
    return {state: 'disconnected'};
  }

  async settle(running) {
    if (this.state === 'disconnected') return;
    let timer;
    const limit = new Promise(resolve => {
      timer = setTimeout(resolve, this.stuckTimeout, 'stuck');
      this.endStuckWait = () => resolve('stopped');
    });
    const finished = running.then(() => 'finished', () => 'finished');
    try {
      if (await Promise.race([finished, limit]) === 'stuck') this.stopInBackground();
    } finally {
      clearTimeout(timer);
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
    const started = this.queue.then(() => {
      if (!isActive()) throw new SkillError('The request ended before its command started.', 4);
      return this.start(request);
    });
    // A timed-out command still holds the queue until it settles, so page actions never overlap.
    this.queue = started.then(({running}) => this.settle(running), () => {});
    return started.then(({running}) => request.command === 'disconnect' ? running : bounded(running, this.commandTimeout, this.timeoutMessage));
  }

  status() { return {state: this.state, release: this.release, profile: this.profile}; }
}

export async function startSession({connectTimeout = 60000, commandTimeout = defaultCommandTimeout, stuckTimeout = defaultStuckTimeout, ...options}) {
  const session = new ChromeSession({...options, connectTimeout, commandTimeout, stuckTimeout});
  await session.listen();
  return {stop: () => session.stop(), ready: session.ready};
}
