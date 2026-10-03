# Security policy

## Reporting a vulnerability

Use this repository's private GitHub security advisory flow. Include the
release, macOS and Chrome versions, Puppeteer version, and reproduction steps.
Keep live credentials, cookies, and session secrets out of the report.

## Access

Chrome's native debugging connection can report tabs across signed-in profiles.
Built-in commands list and operate only on tabs in the verified profile.
Chrome asks you to allow the connection. The skill keeps that connection alive
until disconnect or browser shutdown. Use agents and repositories you trust.

Tab selection is an operational control, not a Chrome permission boundary.
There is no extension tab group boundary. `eval` and `run` execute authorized
page or local script code. They are not a sandbox for untrusted code.

## Controls

- The skill only connects to an already-running normal Chrome on macOS.
- Exactly one normal Chrome main process must exist before attachment. A
  changed process identity causes disconnect before page commands run.
- Connection uses Puppeteer's local stable-channel discovery. The skill accepts
  no caller-supplied remote browser endpoint or browser launch command.
- Native debugging requires Chrome 144 or newer and the user's browser setting.
- The runtime directory belongs to the desktop user, is not a symlink, and has
  mode 0700. The Unix socket has mode 0600. These permissions protect the
  connection from other local users, not processes under the same account.
- A shared connection serializes commands. Ordinary commands never reconnect.
- `disconnect` calls Puppeteer's disconnect API and never closes Chrome.
- `tab-close` refuses to close an existing user tab.
- Attachment and page operations have deadlines. A session deadline ends the
  connection and blocks further commands. JavaScript already running in the
  page can continue. Inspect page state before retrying an action.
- Setup uses exact, integrity-locked `puppeteer-core` dependencies and disables
  npm package scripts. It refuses while a session exists.
- The runtime checks the shipped lock and every installed dependency version
  before loading Puppeteer. It does not run a global browser automation tool.

## Limits

Any process under the same desktop account can access the runtime socket or
change trusted runtime code. The agent, Node.js, npm, Puppeteer, Chrome, local
scripts, and the desktop account remain trusted components. Version checks do
not protect against an attacker who can change files under that account.

Native debugging can affect browser behavior and lets an agent act with your
signed-in permissions. Chrome's approval is required even though the extension
and token are gone. Disconnect when access is no longer needed. Disable native
debugging in Chrome to revoke new connections.

## Supported versions

Security fixes ship for the latest release. The skill pins Puppeteer in
`skills/puppeteer-my-chrome/cli/package-lock.json` and requires Chrome 144 or
newer. Puppeteer's stable-channel connection discovery is experimental, so each
Puppeteer update must pass the connection and lifecycle checks before release.

## Profile checks

`connect --profile` accepts a profile name or directory ID. The skill reads
Chrome profile metadata and returns only names, directory IDs, and the default
choice. It prints no account metadata. It verifies the connected profile through
its own `chrome://version` tab and closes that probe. A profile mismatch blocks task
commands. Chrome chooses the native default profile; this option does not
provide a separate Chrome permission boundary.
