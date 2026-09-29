# AGENTS.md

This file provides guidance to coding agents working with code in this
repository. It is the single source of truth; `CLAUDE.md` is a symlink to it.

## What this repository is

One published Agent Skill, `skills/playwright-my-chrome/`, that lets an agent
drive the Chrome the user already has open and signed in. Everything shipped to
users lives in that directory; the repository root only holds docs, tests, and
CI. macOS and Google Chrome only.

## Commit and push

Never commit or push to the `main` branch. Work on a branch and open a pull
request.

## Commands

```bash
npm run lint      # shellcheck + bash -n on every .sh, then tests/validate_skill.py
npm test          # tests/run.sh, the behavior tests (about a minute)
npm run verify    # both
npx skills@1.5.21 install . --list   # third release check, Skills CLI discovery
```

`npm run lint` needs `shellcheck` on PATH (`brew install shellcheck`).

`tests/run.sh` has no filter flag. It is fast enough to run whole; to isolate one
case, comment out the other calls in the invocation list at the bottom of the
file.

Before any manual check against real Chrome, reinstall first. `npx skills
install` copies the skill directory instead of linking it, so an installed copy
goes stale as soon as `scripts/` changes and would silently test old code:

```bash
npx skills install . --skill playwright-my-chrome --global \
  --agent codex --agent claude-code
```

Then run the installed wrapper's `setup` and use the wrapper from the installed
path, not from this repository.

## Architecture

`scripts/playwright-my-chrome.sh` (about 1900 lines of bash) is the product. It
is a fail-closed wrapper around a private copy of `@playwright/cli`, not a
library. Reading it top to bottom gives the whole design:

1. **Preamble** resolves Node from fixed absolute locations (nvm, Volta,
   Homebrew, `/usr/local`), never through caller `PATH`, and takes the first
   one that meets `engines.node` in `cli/package.json`. It reads the supported
   CLI version from `cli/package-lock.json`, then resets `PATH` to system
   directories so nothing secret-bearing can be shimmed. Every CLI call runs
   `node <runtime>/cli/node_modules/@playwright/cli/playwright-cli.js`. The
   wrapper never looks for a global `playwright-cli`.
2. **Runtime directory** under the user's Caches folder must be private, mode
   0700, non-symlink, and carry a claim file. `<runtime>/cli` gets the same
   directory checks, and a failure exits 6. The wrapper `cd`s there for every
   CLI call, which is how one shared session named `mychrome` stays the same
   from any repository: Playwright CLI picks its daemon session from the nearest
   `.playwright` folder.
3. **Attachment** (`attach_session`) is the security core. It requires exactly
   one normal Chrome main process already running, reads the Keychain token only
   at that point, writes it to the child as an environment variable, and compares
   the full Chrome PID set immediately before and after. A changed PID set, or a
   Chrome command line still carrying the token, detaches and demands token
   rotation.
4. **Cleanup** paths (`scrub_known_output`, `finalize_sanitation`,
   `remove_known_output`) delete only what private, mode-0600, non-symlink
   metadata files name, and refuse traversal-shaped paths.
5. **Setup** (`setup_private_cli`) installs that private copy. Under the
   wrapper lock it removes abandoned `.cli-setup.*` directories and refuses
   while `mychrome` reports `attached: true`, whatever its `compatible` value.
   When the copy cannot run `--json list`, setup refuses only if a process
   still runs code from `<runtime>/cli`. It runs `npm ci --ignore-scripts` on the
   shipped lock in a private staging directory, with the npm next to the
   resolved Node, as a tracked child with a 10 minute bound. It checks the
   staged copy, then moves it into `<runtime>/cli`. A failed, timed-out, or
   interrupted setup kills npm and removes the staging directory. If the old
   copy was already moved aside, the cleanup moves it back. A copy is
   supported (`supported_cli_fault`) when its lock is byte-identical to the
   shipped lock, every locked package is installed at its locked version, and
   `--version` matches. `ensure_session` checks this again after it takes the
   lock, so a concurrent setup cannot swap the CLI before an attach.
   `disconnect` needs only an intact copy (`intact_cli_fault`), so an old
   release's copy can still detach.
6. **Dispatch** at the bottom is an allowlist. `open`, raw `attach`, `show`,
   `install`, `close-all`, and `kill-all` are rejected locally. `setup` is a
   wrapper command, not the forwarded `install`. Help prints the wrapper's own
   usage first, and forwards to the CLI only when the copy is supported. Unknown commands go through
   `ensure_session` and are forwarded with the session flag and token
   redaction.

`scripts/store-extension-token.sh` is the only writer of the Keychain item. It
reads the token from the clipboard, validates its shape, stores it, and clears
the clipboard. The token is never a command-line argument anywhere.

Stable exit codes the tests assert on: `2` private CLI missing or at another
version, or its lockfile unreadable, `3` token unreadable, `4` no owned session
and attaching was not approved, `5` Chrome missing, ambiguous, or changed before
attachment, `6` security fail-closed (including an unsafe `<runtime>/cli`),
`124` attachment timeout, `143` interrupted.

`SKILL.md` is the agent-facing procedure and must stay vendor-neutral and under
500 lines. `agents/openai.yaml` is host UI metadata only; nothing reads it at
runtime.

## Invariants the checks enforce

- **`cli/package-lock.json` is the only source of the supported CLI version.**
  `validate_skill.py` checks that `cli/package.json` declares one exact
  `@playwright/cli` version as its only dependency and that the lock matches
  it. It fails if any file outside `cli/` and `docs/` spells that version.
  Docs, tests, and CI read the version from the lock.
- **A CLI bump changes only `cli/package.json` and `cli/package-lock.json`.**
  Set the new version in `cli/package.json`, then regenerate the lock with
  `npm install --package-lock-only --ignore-scripts --prefix
  skills/playwright-my-chrome/cli`. Before merging, audit the new release
  against every CLI behavior the wrapper depends on, and record the audit in
  the implementation notes.
- **No machine-specific home paths and no Unicode dashes in any tracked file**,
  including this one. `validate_skill.py` scans the whole repository, not only
  the skill.
- **Tests never touch the real world.** Keychain, `ps`, clipboard, npm, and the
  Playwright CLI are replaced by `tests/mocks/*.sh` through
  `PLAYWRIGHT_MY_CHROME_TEST_*` environment variables, with `HOME` pointed at a
  temporary directory. A test that needs a real browser, token, or Chrome
  profile is not acceptable.
- **Every safeguard change needs a regression test.** This is not waived, per
  CONTRIBUTING.md.
- **Fail-closed stays fail-closed.** If a change touches the missing or
  unsupported CLI path, or the unclear-Chrome-state path, explain what the
  failure branch does.

## Notes

Design decisions, rejected alternatives, and per-release verification live in
`docs/open-source-release/implementation_notes.md`. Read it before revisiting a
choice that looks arbitrary; most of them were deliberate.

Security-sensitive findings go through a private GitHub advisory, never a pull
request or issue.
