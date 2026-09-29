# Implementation notes

The decisions behind this project, the options that were turned down, and how
each release was verified.

## Purpose

Let a coding agent drive a Chrome that is already open and signed in. Not a
fresh browser, not a headless one. The real profile with its existing sessions.

`playwright-my-chrome` is a vendor-neutral Agent Skill. It installs through the
Vercel Skills CLI and runs under Codex, Claude Code, or any other agent running
in the same macOS desktop session as Chrome.

## Decisions

### Layout and portability

- Use the Agent Skills `skills/<name>/SKILL.md` layout. The instructions and the
  runtime scripts depend on no agent vendor, so the project is not tied to one
  host.
- Keep `agents/openai.yaml` optional. It carries UI metadata only, and nothing
  at runtime reads it.
- Make `npx skills install` the public command, and keep the `add` alias working
  so both spellings behave the same.
- Put the MIT notice inside the skill directory as well as the repository root.
  Skill installers copy only that directory, so a license at the root alone
  would never reach an installed copy.

### Safety, because the wrapper holds a real token

- Pin one exact `@playwright/cli` version. Browser commands fail closed on
  every other version. Attachment and daemon behavior are security sensitive,
  and a future release may not keep the same guarantees. The pin was 0.1.17 at
  first release. Since 2026-09-29 it lives only in `cli/package-lock.json`, and
  the wrapper runs a private copy of it (see that section below).
- Store the extension token in macOS Keychain and never accept it as a command
  argument. Setup reads the clipboard and clears it afterwards.
- Require exactly one normal Chrome main process, and compare the complete PID
  set immediately before and after attachment. Detach if it changed.
- Bound attachment to 60 seconds. On timeout, kill the exact child that was
  started, attempt a named-session detach, remove the private artifacts, and
  require token rotation.
- Reuse one private `mychrome` session across agents for the same desktop user,
  so two agents do not fight over the extension connection.

### Disclosed rather than papered over

The Playwright CLI daemon inherits the token-bearing environment for as long as
the session is attached. That is upstream behavior this project cannot remove.
It is documented in `SECURITY.md` as a residual risk, and `disconnect` is the
supported way to shorten the exposure window.

### CI

Development dependencies are locked, and no mutable package install runs in CI.
The Ubuntu runner uses its own bundled ShellCheck for static analysis. macOS
runs the behavior and installation tests.

## What was turned down

- **Chrome DevTools Protocol.** It needs a separately launched debugging
  browser, which defeats the point of using an already signed-in profile.
- **Browser APIs and vendor connectors.** The requirement was Playwright driving
  the real rendered Chrome UI, not a service reaching the site another way.
- **AppleScript and machine-wide Chrome process control.** Both bypass
  Playwright and can affect browser instances unrelated to the task.
- **Printing failed attachment logs and redacting them afterwards.** Passing a
  live token to a redaction process still exposes it to anyone who can list
  process arguments. Capturing and scrubbing without printing is the only
  version that holds.
- **Homebrew in CI.** It runs mutable remote content during the build. For a
  project whose job is guarding a credential, that is the wrong trade.

## Corrections made during development

- An early cut was shaped around one agent host. That was pulled back out to
  keep the skill agent-agnostic and compliant with the Agent Skills standard, so
  it does not rot when the host changes.
- Recovery was disarming too early. It now stays armed until the post-attach PID
  checks, the process-token check, helper-tab validation, and private-output
  sanitation have all finished.
- Interrupt handling was added for both attach and post-attach validation. On
  interrupt the wrapper terminates the tracked CLI child, unsets the token
  environment, attempts a token-free named detach, and deletes the private
  bootstrap artifacts.

## First release verification

All on macOS:

- `npm run verify`: ShellCheck, project validation, and all 21 behavior tests
  under Bash 3.2.
- Agent Skill quick validation: passed.
- Strict skill security scan: 0 findings across 7 files and 2 scripts.
- Workflow and host-metadata YAML parsing: passed.
- Locked dependency audit: 0 vulnerabilities.
- Real `@playwright/cli` 0.1.17 `doctor` smoke test: passed.
- Vercel Skills 1.5.21 discovery and copy installation: passed for Codex, Claude
  Code, the universal target, and the wildcard all-agent target.
- Installed copies kept the MIT license and the executable script modes.
- Independent shell, installation, and security reviews: publish PASS with no
  remaining blockers.
- Interruption coverage runs against a token-bearing attach child and against a
  successful attachment paused in post-attach tab validation. Both tests check
  token-free detachment and artifact cleanup.

Public installation, repository security settings, hosted CI, and the release
tag were left as post-push steps.

## 2026-07-30: rename and documentation rewrite

### Rename

The project was renamed from `playwright-active-chrome` to
`playwright-my-chrome`.

"Active" was the weakest word in the old name. Most readers, and especially
non-native English readers, take "active" to mean "the tab in front" rather than
"the browser already open". "My" carries the intended meaning with no second
reading.

Every identifier moved, not only the repository name. A half-renamed project
reads as a mistake:

- the skill directory and the skill `name`
- the wrapper script, from `playwright-cli-active.sh` to
  `playwright-my-chrome.sh`
- the environment variable prefix, from `PLAYWRIGHT_ACTIVE_CHROME_` to
  `PLAYWRIGHT_MY_CHROME_`
- the shared session, from `activechrome` to `mychrome`
- the Keychain service, to `playwright-my-chrome.extension-token`
- the default runtime directory, to `$HOME/Library/Caches/playwright-my-chrome`
- the runtime claim marker, to `playwright-my-chrome-runtime-v1`

Internal messages that used "active Chrome" as plain English were reworded too,
so the word does not return through the error output.

The Keychain service and the runtime directory hold state, so an existing
install does not migrate itself. Move the stored token with
`store-extension-token.sh --migrate-from-service`, then delete the old cache
directory.

No compatibility shim was added. The rename landed a few hours after the first
publish, before anyone had installed the old name, so there was nothing to stay
compatible with. Deferring it would have cost a permanent redirect and a
deprecation note, and kept the weaker name.

### Documentation

The old README served a reader who had already decided to use the project, not
one still deciding.

What changed and why:

- The macOS and Chrome requirement moved to the top. It decides whether the
  reader can use the project at all, and it was sitting halfway down the page.
- Added "What it looks like" with a real prompt. The old page never showed what
  using the skill feels like.
- Documented the green Playwright tab group. That instruction existed only in
  `SKILL.md`, and it is the first thing a new user needs.
- Collapsed three install commands into one. Three variants before the reader
  has done anything is a choice they are not ready to make.
- Rewrote the safeguard list so every line starts with a subject and a verb. The
  old list stacked abstract nouns, which is the hardest shape to read in a
  second language.
- Added a Troubleshooting table built from the real `doctor` output in the
  wrapper rather than from assumption. Writing it showed two states the docs
  never mentioned: `chrome: ambiguous` and `session: stale`.
- Added CI, license, and platform badges, and a short Contributing section.

The page grew in words. Concise means no wasted words, not fewer answers.

`SECURITY.md` and `CONTRIBUTING.md` were rewritten against the same readability
bar: short sentences, plain words, and every list item starting with a subject
and a verb.

### Rename verification

- `tests/lint.sh`: passed.
- `tests/run.sh`: 21 of 21 behavior tests passed after the rename.
- `npx skills@1.5.21 install . --list`: found the skill under the new name.
- Keychain token migrated with `--migrate-from-service`. `doctor` then reported
  `token: stored` and the new `playwright-my-chrome` workspace path.
- `safety-audit` on the installed copy against real Chrome: all 7 safeguards
  passed.
- Hosted CI on the rename commit: green.

The stale `$HOME/Library/Caches/playwright-active-chrome` directory was scanned
for token material before deletion. It was clean, which confirmed the wrapper's
scrubbing had been working. Old-name installs were removed and replaced with a
single global install of the new name.

The old Keychain item `playwright-active-chrome.extension-token` was kept until
the new one was proven, then deleted on request:

```bash
security delete-generic-password \
  -a "$(id -un)" \
  -s playwright-active-chrome.extension-token
```

Order matters here. `doctor` only reports whether a Keychain item exists, not
whether it authenticates, so the old copy stayed until a live `connect` had
succeeded on the new one. After deleting it, `connect`, `goto`, and `disconnect`
were run again to confirm the skill still authenticates with a single stored
credential.

A live connection was then taken against real Chrome to close the last gap:

- `connect` reported ready on the renamed `mychrome` session.
- `doctor` reported `session: ready` and `process-token: absent`, so the token
  did not reach the Chrome command line during a real attachment.
- `tab-list` returned the extension helper tab and the clean controlled tab,
  with the helper's authentication query redacted in the forwarded output.
- `goto https://example.com` loaded the page and returned its title, which
  proves the session actually drives the browser.
- `disconnect` detached and left Chrome running on the same PID it started on.

## 2026-09-29: a private, lockfile-pinned Playwright CLI at 0.1.21

### Problem

The wrapper found `playwright-cli` in global install locations (nvm, Volta,
Homebrew, `/usr/local`) and refused every version except its pin. Other skills,
such as verify-ui, use and upgrade that same global CLI. Each global upgrade
broke this skill until someone edited the pin in five files. That does not
scale.

### Decision

The skill owns a private copy of the CLI, separate from the global one:

- `skills/playwright-my-chrome/cli/package.json` declares one exact
  `@playwright/cli` dependency, and `cli/package-lock.json` locks it with
  integrity hashes. The lock is the only source of the supported version. A
  bump changes only these two files.
- The wrapper reads the supported version from the shipped lock at runtime. A
  missing or unreadable lock exits 2.
- The wrapper command `setup` installs the private copy into
  `<runtime>/cli`. Under the wrapper lock, it copies the manifest and lock
  into a private staging directory and runs `npm ci --ignore-scripts
  --omit=dev --no-audit --no-fund`. It uses the npm next to the resolved
  Node, with only the Node directory and system directories on `PATH`. It
  checks the staged `--version` against the lock, then moves the copy into
  place and removes the old one. It does nothing when the installed copy
  already matches. A failed or interrupted setup removes the staging
  directory, so no partial copy is left.
- Every CLI call runs `node <runtime>/cli/node_modules/@playwright/cli/playwright-cli.js`.
  The global discovery code and the `PLAYWRIGHT_MY_CHROME_CLI` override were
  deleted, with no fallback.
- A missing private copy or a version mismatch exits 2 before any token or
  browser access, and the message names the exact `setup` command. An agent
  runs `setup` and retries. The user runs no manual step.
- The root `package.json` no longer needs `@playwright/cli`. CI runs the real
  `setup` and `doctor` and reads the expected version from the shipped lock.

Turned down:

- **Vendoring `node_modules` into the skill.** It would ship a large
  third-party tree in every install and every diff.
- **Keeping global discovery with a pin.** That is the design that broke on
  each global upgrade.
- **Widening the check to a version range.** Every release still needs the
  audit below before the wrapper trusts it.

### Audit of 0.1.21 against 0.1.17

0.1.21 is the version a global install resolved to when this change started.
It was chosen over the newer 0.1.22 because it was the release already
installed and audited.

The 0.1.21 package moves `playwright-core` from 1.62.0-alpha to 1.64.0-alpha.
The audit compared both bundles on each behavior the wrapper depends on:

- `--version` still prints the bare version on stdout.
- `--json list` builds each entry from the same fields: `name`, `workspace`,
  `browserType`, `status`, `attached`, and `compatible`.
- Daemon workspace discovery still walks up to the nearest `.playwright` folder.
- `tab-list` still renders each tab as `- N: [title](url)`. The new WebMCP
  tool-count line appears only in the current-page section, not in the tab list.
- The token is still read from `PLAYWRIGHT_MCP_EXTENSION_TOKEN` and still reaches
  Chrome only as the `token` query parameter of the connect page, so the
  process-token check still matches it.
- The top-level command list gained emulation, `recording-start`,
  `recording-stop`, `webmcp-list`, and `webmcp-call`. All of them act on the
  attached page and go through `ensure_session`. No command that launches a
  browser, attaches, or ends other sessions was added.

Upstream changes that affect attachment:

- Extension protocol v1 is gone. The official extension already speaks v2.
- A token-bearing attach now gives up after 30 seconds without an extension
  connection. The wrapper's 60 second bound still covers it, and the upstream
  error names the variable, not its value.
- The handoff launch adds `--profile-directory=<dir>` for the profile where the
  extension is installed. `normal_chrome_pids` does not exclude that flag, so
  the process continuity checks behave as before.

### Fixes after independent testing

An independent tester found eight issues. Each fix has a regression test:

- `npm ci` ran as a foreground child, so bash held TERM and INT until npm
  ended, and the wrapper lock stayed held. Setup now runs npm through the
  bounded runner the attach path uses, with a 10 minute bound. A signal or a
  timeout kills npm, removes the staging directory, and releases the lock.
  A background job starts with SIGINT ignored, so the INT test starts the
  wrapper through `perl` to restore the default.
- `<runtime>/cli` had no private-directory checks, and a symlink made the
  wrapper run code from outside the runtime. It now gets the checks that the
  lock directory gets. A failure exits 6, not 2, because `setup` cannot
  repair it and the CLI receives the token.
- Setup now removes abandoned `.cli-setup.*` directories that pass the same
  checks, and leaves anything else in place with a warning.
- "Supported" and "already installed" used to mean only that `--version`
  matched. They now also need a byte-identical lock and every locked package
  at its locked version. Deleting `<runtime>/cli` forces a reinstall. No
  `--force` flag was added.
- `--help`, `-h`, and a bare call used to exit 2 before setup. They now always
  print the wrapper's usage, and add the CLI help only when the copy is
  supported.
- The README used relative script paths. It now uses the default global path,
  `~/.agents/skills/playwright-my-chrome`.
- `SKILL.md` and `cleanup-plan` told the agent to run the global
  `playwright-cli` for other sessions. Both now say to leave those sessions to
  the tool that owns them.
- Setup replaced the CLI under an attached daemon. It now refuses while
  `mychrome` is attached and asks for `disconnect`. Setup never detaches on its
  own. `disconnect` accepts an intact copy from another release, so that path
  cannot deadlock after a skill update.

A retest found one more issue, and the user asked for one new safeguard:

- The help fix sent a bare `--version` to the wrapper usage. `--version` and
  `-v` are now handled before help. They print only the version, and exit 2
  naming `setup` before setup.
- On the user's machine, another agent had written the Keychain item as
  `PLAYWRIGHT_MCP_EXTENSION_TOKEN=<token>`, and the extension rejected it.
  `read_token` already checked the `^[A-Za-z0-9_-]{32,128}$` shape and exited
  3 before attach, so the stored value never reached the extension. That
  attempt most likely came from a caller other than this wrapper. The refusal
  now names the in-place repair,
  `store-extension-token.sh --migrate-from-service playwright-my-chrome.extension-token`.
  Tests cover a prefixed value and two other malformed values, and check that
  no attach runs and no value reaches the output. The token is still read
  after the Chrome preflight, not before, so the rule that a missing Chrome
  never triggers a token read still holds. The one-line shape check stays in
  both scripts. A shared sourced file would add a second file on the path
  that handles the token, for one regular expression.

### Fixes from the Codex review of PR #2

A test reproduced each finding before its fix, except the interrupted move,
which a code trace confirmed. Its test must pause the move command, so the
wrapper now resolves `mv` like its other system commands, and tests replace
it.

- Setup went ahead under a session that was attached but reported
  `compatible: false`, because that reads as `stale`. Setup now reads
  `attached === true` for the session name directly. When the copy cannot run
  `--json list`, setup looks for any process whose command line runs code from
  `<runtime>/cli`, by logical or physical path. It refuses only when one
  exists. Refusing on every unreadable copy would deadlock, because
  `disconnect` also needs a working copy. The upstream daemon starts as
  `node <copy>/node_modules/playwright-core/lib/entry/cliDaemon.js <session>`,
  so this check finds it.
- `connect` checked the CLI before it took the lock, so a concurrent setup
  could replace the CLI before the token went out. `ensure_session` now
  checks the CLI after it takes the lock. The earlier check in dispatch was
  removed for the commands that go through `ensure_session`, so each command
  checks once.
- An interrupt between the two moves deleted the previous copy with the
  staging directory. The staging cleanup now moves the previous copy back when
  the new copy never reached `<runtime>/cli`.
- `resolve_node` took the nvm node with the newest file time. It now takes the
  first candidate that meets `engines.node` in `cli/package.json`. For nvm it
  reads the version from the directory name, so it runs no old node. The
  chosen binary is then checked by running it. Without a qualifying node the
  wrapper exits 1 and names the minimum.

The process check first shipped with a bug. It passed the copy's path to
`awk` as an argument, so `awk` found its own command line in the `ps` output,
and `setup` failed on every fresh install. The mock `ps` returns a fixed file,
so the tests missed it. The paths now reach `awk` through the environment. A
line counts only when a node executable runs a script from the copy. One test
feeds `awk`, `grep`, and `cat` lines that hold the path, and expects setup to
go ahead. Another test runs the real `/bin/ps` against a stand-in node process
started from the copy.

### Verification

- `npm run verify`: ShellCheck, project validation, and 44 behavior tests
  passed.
- A throwaway `HOME` install with the real process list and real npm: `setup`
  installed 0.1.21, a second `setup` reported it already installed, `doctor`
  reported supported, and `setup` on a copy with `playwright-core` deleted
  reinstalled it.
- Mutation checks for this round: ignoring `compatible` in the attached check,
  skipping the process check, removing the check under the lock, removing the
  restore, and removing the nvm version filter each made a test fail.
- The CI smoke step, run locally with real npm: `setup` installed 0.1.21 into a
  temporary runtime, and `doctor` reported `compatibility: supported`.
- Packaging: `npx skills install` into a temporary `HOME` for Codex and Claude
  Code copied `cli/package.json` and `cli/package-lock.json`. The installed
  wrapper exited 2 on `connect` and named `setup`. Its `setup` installed 0.1.21
  with real npm, a second `setup` reported it already installed, and `doctor`
  reported `compatibility: supported (requires 0.1.21)`. `--help` printed the
  wrapper usage and then the real CLI help. After deleting
  `<runtime>/cli/node_modules/playwright`, `doctor` reported the copy as
  incomplete, and `setup` reinstalled it.
- Mutation checks: removing `--ignore-scripts`, the staging cleanup, the
  staged version check, the attached-session refusal, the abandoned-staging
  cleanup, the CLI directory check, or the lock comparison each made a
  behavior test fail.
