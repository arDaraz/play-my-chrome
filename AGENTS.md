# Repository instructions

This repository publishes `skills/play-my-chrome`, a macOS Agent Skill
that launches installed Chrome on a private, persistent profile and controls it
through Puppeteer over a debugging pipe.

## Delivery

Work in a task worktree on a branch and open a pull request. Never commit or
push to `main`. Keep implementation records outside this public repository.

## Runtime

All shipped files live in the skill directory. `scripts/play-my-chrome.sh`
selects trusted Node and invokes `cli.mjs`. The local session keeps a Puppeteer
connection alive through a private Unix socket. Only `connect` starts a daemon,
and that daemon launches Chrome. The runtime installs locked `puppeteer-core`
privately and never downloads a browser. Keep the installed dependency version
in its lockfile.

Launch only `/Applications/Google Chrome.app` with `--remote-debugging-pipe`,
`ignoreDefaultArgs`, and the private profile. Never add a debugging port, a
user-supplied endpoint or flag, an extension, or a credential. Never attach to
or edit the normal Chrome profile. The `login` window and the session must share
every flag that affects stored data. Preserve private directory, marker, and
socket checks, the profile-in-use check, request validation, serial execution,
and connection deadlines. A failed preflight must stop before launching. A
command timeout must keep the session open, because closing it loses the tabs.
Later commands wait until the timed-out command finishes. A command stuck past
the hard limit must end the session and close Chrome.

## Verification

Run `npm run verify` and the locked Skills CLI discovery and copy-installation
checks before publishing. Tests use fake browsers, temporary sockets, and
temporary profile directories. They must not use real profiles, browser
credentials, clipboard, or Keychain.
Add a behavior test for each changed safeguard or fixed bug. Keep the skill
vendor-neutral, under 500 lines, and free of machine-specific home paths.

Before a manual real-browser check, install a fresh copy of the skill with the
Skills CLI. Run the installed wrapper's `setup`, then test from the installed
path, with `PLAY_MY_CHROME_PROFILE_DIR` set to a temporary directory. This
verifies the package users receive rather than a stale local copy. A sign-in
that needs the user is a pending live check, not a successful test.
