# Security policy

## Reporting a vulnerability

Use this repository's private GitHub security advisory flow. Include the
release, macOS and Chrome versions, Puppeteer version, and reproduction steps.
Keep live credentials, cookies, and session secrets out of the report.

## Access

The skill launches Chrome on its own private profile and never attaches to the
user's normal Chrome. That profile holds every login the user adds with
`login`, and an agent that uses the skill acts with those permissions. Use
agents and repositories you trust, and add only the logins the agent needs.

`eval` and `run` execute authorized page or local script code. They are not a
sandbox for untrusted code.

## Controls

- The skill runs only on macOS and launches only
  `/Applications/Google Chrome.app`. It accepts no caller-supplied browser
  executable, endpoint, or launch flag.
- `connect` launches headless Chrome with `--remote-debugging-pipe`. The
  debugging channel is a pipe inherited by the session process, so no TCP port
  or `DevToolsActivePort` file exists.
- `login` opens a visible Chrome on the private profile with no debugging
  channel. It refuses while a session is active.
- The private profile directory belongs to the desktop user, is not a symlink,
  and has mode 0700. It holds an ownership marker, so the skill refuses a
  non-empty directory it did not create. It cannot be inside the normal Chrome
  user data directory.
- `connect` and `login` refuse while any Chrome process uses the private
  profile.
- The runtime directory has the same ownership checks. The Unix socket has mode
  0600. These permissions protect the session from other local users, not from
  processes under the same account.
- A shared session serializes commands. Ordinary commands never reconnect.
- `disconnect` closes the skill's Chrome. The session also closes it when a
  launch finishes after the connection deadline.
- `tab-close` closes only a tab created during the current session.
- Launch and page operations have deadlines. A command past its deadline
  reports a timeout and blocks further commands until it finishes. A command
  still running after five minutes ends the session and closes Chrome.
- Setup uses exact, integrity-locked `puppeteer-core` dependencies and disables
  npm package scripts. It refuses while a session exists.
- The runtime checks the shipped lock and every installed dependency version
  before loading Puppeteer. It does not run a global browser automation tool.

## Limits

Any process under the same desktop account can access the runtime socket, read
the private profile, or change trusted runtime code. The agent, Node.js, npm,
Puppeteer, Chrome, local scripts, and the desktop account remain trusted
components. Version checks do not protect against an attacker who can change
files under that account.

Chrome encrypts the profile's cookies with its normal macOS Keychain item.
Sign out of a site in a `login` window, or delete the private profile
directory, to remove its stored logins.

## Supported versions

Security fixes ship for the latest release. The skill pins Puppeteer in
`skills/play-my-chrome/cli/package-lock.json`. Each Puppeteer update must pass
the launch and lifecycle checks before release.
