import {createConnection} from 'node:net';
import {lstatSync, unlinkSync} from 'node:fs';
import {join} from 'node:path';
import {assertPrivate} from './runtime.mjs';
import {SkillError} from './errors.mjs';

export const requestLimit = 1024 * 1024;
// A queued request can wait behind a slow command until the session's stuck-command limit.
export const requestTimeout = 6 * 60 * 1000;

export function socketPath(runtime) {
  return join(runtime, 'session.sock');
}

export function sendRequest(runtime, request) {
  const path = socketPath(runtime);
  if (!lstatSync(path, {throwIfNoEntry: false})) return Promise.reject(new SkillError('No session is connected. Run connect.', 4));
  assertPrivate(path, 'socket');
  return new Promise((resolve, reject) => {
    const socket = createConnection(path);
    let response = '';
    socket.setEncoding('utf8');
    socket.setTimeout(requestTimeout, () => socket.destroy(new SkillError('Session request timed out. Run doctor.', 124)));
    socket.once('connect', () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on('data', chunk => {
      response += chunk;
      if (Buffer.byteLength(response) > 8 * requestLimit) socket.destroy(new SkillError('Session response exceeds 8 MB. Use a smaller page query.'));
    });
    socket.once('error', reject);
    socket.once('end', () => {
      try {
        const reply = JSON.parse(response);
        if (reply.error) throw new SkillError(reply.error, reply.exitCode);
        resolve(reply.payload);
      } catch (error) { reject(error); }
    });
  });
}

export async function sessionStatus(runtime) {
  const path = socketPath(runtime);
  const identity = lstatSync(path, {throwIfNoEntry: false});
  try {
    return await sendRequest(runtime, {command: 'status', args: []});
  } catch (error) {
    if (error.exitCode === 4) return {state: 'missing'};
    if (error.code !== 'ECONNREFUSED' && error.code !== 'ENOENT') throw error;
    if (identity && lstatSync(path, {throwIfNoEntry: false})?.ino === identity.ino) {
      assertPrivate(path, 'socket');
      unlinkSync(path);
    }
    return {state: 'missing'};
  }
}
