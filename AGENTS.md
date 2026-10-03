# Repository instructions

This repository publishes `skills/puppeteer-my-chrome`, a macOS Agent Skill
that controls an already-running signed-in Chrome through Puppeteer's native
connection. The repository URL retains its former name.

## Delivery

Work in a task worktree on a branch and open a pull request. Never commit or
push to `main`. Keep implementation records outside this public repository.

## Runtime

All shipped files live in the skill directory. `scripts/puppeteer-my-chrome.sh`
selects trusted Node and invokes `cli.mjs`. The local session keeps a Puppeteer
connection alive through a private Unix socket. Only `connect` starts a daemon.
The runtime installs locked `puppeteer-core` privately and does not download,
launch, or close Chrome. Keep the installed dependency version in its lockfile.

Use native stable-channel discovery, not a user-supplied endpoint, extension,
credential, or remote debugging launch flag. Preserve process identity checks,
private directory and socket checks, request validation, serial execution,
connection deadlines, named profile checks, and disconnect-only cleanup.
A failed preflight must stop before connecting. A timeout must block further
commands. Page JavaScript can continue after disconnect.

## Verification

Run `npm run verify` and the locked Skills CLI discovery and copy-installation
checks before publishing. Tests use fake browsers and temporary sockets. They
must not use real profiles, browser credentials, clipboard, or Keychain.
Add a behavior test for each changed safeguard or fixed bug. Keep the skill
vendor-neutral, under 500 lines, and free of machine-specific home paths.

Before a manual real-browser check, install a fresh copy of the skill with the
Skills CLI. Run the installed wrapper's `setup`, then test from the installed
path. This verifies the package users receive rather than a stale local copy.
A missing native debugging setting or unanswered Chrome dialog is a pending
live check, not a successful test.
