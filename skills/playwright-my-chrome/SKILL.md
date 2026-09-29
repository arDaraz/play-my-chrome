---
name: playwright-my-chrome
description: Control the user's already-running, logged-in Google Chrome through Playwright CLI and the official Playwright Extension. Use when the user explicitly asks to use Playwright with their active, current, existing, or signed-in Chrome session; asks to inspect or operate a website through that rendered browser UI; or forbids APIs, browser connectors, or a newly launched browser. Reuse the shared mychrome session and never silently substitute an API, connector, AppleScript, or another browser.
---

# Playwright My Chrome

Use the official Playwright Extension through this skill's wrapper. Preserve the
user's existing Chrome profile, cookies, logins, and tabs.

This skill is agent-host-neutral and relocatable, while its browser runtime is
macOS-specific. `SKILL_ROOT` below means the absolute directory containing this
`SKILL.md`. Resolve it from the skill path provided by the host agent, and
invoke the scripts by absolute path. Do not assume a particular agent vendor,
home-directory layout, or current working directory.

## Host integration

Keep one canonical copy of this whole directory. A host that supports agent
skills can symlink or copy it into that host's configured skill-discovery
directory. A host without automatic discovery can load this `SKILL.md` by
absolute path. There is no universal discovery directory, so discovery adapters
must remain outside the runtime contract.

The optional file under `agents/` supplies host UI metadata only. The core
instructions and scripts do not depend on it.

## Runtime contract

Use this wrapper for every command:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh"
```

Resolve `SKILL_ROOT` to its absolute path before invoking the wrapper. Do not
pass an unset or literal `SKILL_ROOT` variable to the shell.

The wrapper:

- uses one `mychrome` daemon session across agents and repositories for the
  same local desktop user;
- isolates that session in a private, agent-host-neutral `.playwright`
  workspace;
- runs only its own private copy of Playwright CLI, installed by `setup` from
  the skill's lockfile, and never runs or changes a global `playwright-cli`;
- confirms that normal user Chrome is already running before every fresh
  attachment and refuses to launch Chrome itself;
- requires exactly one normal Chrome main process, verifies that the complete
  PID set survives attachment, and fails closed if it changes or retains the
  token;
- checks that the owned session and extension connection are healthy;
- never attaches implicitly or disconnects an extension client owned by
  another tool;
- serializes concurrent attach attempts;
- reads the extension token only for a fresh attachment or explicit
  token-rotation verification;
- captures and scrubs the attach command's token-bearing bootstrap output;
- creates and verifies a clean controlled tab, then parks the required
  extension helper safely in the background;
- redacts the helper's authentication query from forwarded CLI output; and
- bounds attachment to 60 seconds and helper-tab commands to 8 seconds so a
  stalled relay cannot leave the wrapper lock hanging indefinitely.

Default shared state:

- session: `mychrome`
- runtime: `$HOME/Library/Caches/playwright-my-chrome`
- Keychain service: `playwright-my-chrome.extension-token`
- Keychain account: the current macOS username

These environment variables provide configuration overrides:

- `PLAYWRIGHT_MY_CHROME_NODE`
- `PLAYWRIGHT_MY_CHROME_RUNTIME_DIR`
- `PLAYWRIGHT_MY_CHROME_SESSION`
- `PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE`
- `PLAYWRIGHT_MY_CHROME_KEYCHAIN_ACCOUNT`
- `PLAYWRIGHT_MY_CHROME_EXECUTABLE`

The Node override must be an absolute path to a trusted Node.js executable.
Without it, the wrapper checks only standard absolute NVM, Volta, Homebrew, and
`/usr/local` locations. It never selects Node through caller-controlled `PATH`.
The wrapper uses the first Node.js that meets the `engines.node` minimum in
`cli/package.json`, starting with the newest qualifying nvm install. When none
qualifies, it exits with status 1 and names the minimum.
A runtime override must also be absolute and point to a dedicated, non-symlink
directory owned by the desktop user. The wrapper creates new runtime directories privately and
refuses to claim a non-empty unrelated directory or modify its permissions.
The Chrome executable override is only for another trusted Chrome installation
such as Chrome Canary. The default is standard macOS Google Chrome.

Every agent that should reuse the same browser connection must use the same
runtime directory and session name. Every agent that may perform an explicitly
approved fresh connection must use the same Keychain service and account.

When `doctor` reports `session: ready`, call the desired command directly:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" tab-list
```

An explicitly approved `connect` after Chrome, the extension, or the Playwright
daemon restarts may briefly display the extension's `connect.html` page. This is
the official extension handshake, not user content. The CLI opens it
unconditionally on a fresh extension attachment. Do not inspect it, report it
as the requested page, or repeatedly reconnect because it appeared.

The wrapper creates a controlled blank tab, verifies that it is attached, and
parks the helper in the background. The helper must remain open because it owns
the extension heartbeat. Navigating or closing it will tear down the session.
Keeping the shared session alive prevents it from taking focus during normal
use.

## One-time configuration

This local implementation requires macOS, Google Chrome, the official
Playwright Extension, Bash, Node.js 22.20 or newer with its bundled npm, and
macOS Keychain. Different agent hosts can load the skill from any location, but
they must run as the same logged-in desktop user to share that Chrome instance.

The skill pins one exact `@playwright/cli` version in `cli/package-lock.json`.
The wrapper runs a private copy of that version from `<runtime>/cli` and
ignores any global `playwright-cli`. When the private copy is missing,
incomplete, or from another skill release, every browser command exits with
status 2 before it reads the token or touches Chrome. The message names this
command:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" setup
```

On exit status 2, run `setup`, then retry the command once. `setup` needs
network access to the npm registry and is safe to run twice. The first use and
every skill update that ships a new lockfile each need one `setup`. To force a
reinstall, delete `<runtime>/cli` and run `setup`.

`setup` refuses while the `mychrome` session is attached, because it replaces
the CLI that session runs from. When that happens, run `disconnect`, then
`setup`, and ask for approval again before `connect`. `disconnect` still works
with an intact copy from an earlier skill release. If the copy is too damaged
to report the session and a process still runs from it, `setup` names that
process ID. Report it to the user, and never stop that process yourself.

A `SECURITY:` message about `<runtime>/cli` with exit status 6 means that
directory is a symbolic link, belongs to another user, or does not have mode
0700. Stop and report it to the user. `setup` refuses to replace it.

`--help`, `-h`, and a call with no command print the wrapper's own commands.
They add the Playwright CLI command list only when the private copy is
supported. `--version` and `-v` print only the private CLI version, and exit
with status 2 before `setup`. `doctor` reports the private CLI path, its version, the required
version, and compatibility.

Complete these steps once per macOS user and Chrome profile:

1. Install and enable the official Playwright Extension in the Chrome profile
   that contains the signed-in sessions to automate.
2. Open Chrome manually. Never depend on `connect` to start it.
3. Open the extension connection page. Regenerate the extension token with the
   circular-arrow button so any previously exposed value is invalidated.
4. Copy the token with the extension's copy button. Never paste it into chat or
   a terminal command.
5. While the token remains on the clipboard, run:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh"
```

The script validates the token without printing it, stores it in macOS
Keychain, and clears the clipboard after success.

To move an existing token from a previous service name without exposing it or
deleting the old entry:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh" \
  --migrate-from-service "<previous-keychain-service>"
```

After verifying the new configuration, the old Keychain item may be removed
separately if the user requests it.

Check readiness without displaying or retrieving the token:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" doctor
```

`token: stored` means an explicitly approved `connect` can authenticate without
printing the secret. `doctor` checks only whether the Keychain item exists.
`session: missing` is normal before the first approved `connect`. `chrome: missing` means
the wrapper will refuse to attach until the user opens Chrome.
`process-token: exposed` requires the rotation procedure described under Security.

Verify all enforced safeguards:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" safety-audit
```

## Normal workflow

The wrapper selects `mychrome` automatically. Do not add
`-s=mychrome` unless compatibility with an existing command requires it.

The Playwright Extension permits only one active client at a time, and a
connection owned by another tool is not necessarily visible in this wrapper's
session registry. Ordinary commands therefore never attach when this skill's
session is missing or stale. Require explicit user approval before taking the
exclusive extension connection. Honor approval already present in the current
task; do not request it again. Then run:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" connect
```

`connect` must fail without opening a browser unless exactly one normal Chrome
main process is already running. Do not bypass that preflight, call the
underlying `attach` directly, or use `open`. The wrapper blocks `attach`,
`open`, `show`, `install`, `close-all`, and `kill-all`. The wrapper's own
`setup` command is not the blocked browser `install`.

Do not infer approval from a generic browser task. Once `connect` reports ready,
keep the session alive and issue ordinary commands without an additional setup step.

The token-based extension handshake does not automatically take control of
every tab already open in Chrome. It starts with the clean controlled tab
prepared by the wrapper. Existing user tabs stay open and untouched.

To operate an already-open tab, ask the user to drag that tab into the green
Playwright tab group in Chrome, then list the tabs exposed by the extension:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" tab-list
```

Navigate the controlled tab:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" goto "https://example.com"
```

Create another controlled tab:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" tab-new "https://example.com"
```

Use `goto` when a separate tab is unnecessary. Use snapshots, `find`, locators,
and `eval` to inspect the rendered page. Base answers only on browser-visible
state, and verify the final URL and result.

Use absolute paths for uploads, downloads, scripts, screenshots, and saved
state because the shared session runs from its neutral runtime directory.

Keep the session attached between related tasks. Disconnect only when the user
explicitly requests it, or when troubleshooting requires a clean attachment:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" disconnect
```

`disconnect` maps to Playwright CLI `detach`, verifies that normal Chrome
remains running, and never closes the external browser. Disconnect after use
when minimizing token exposure is more important than session reuse.

## Diagnostics and recovery

Run `doctor` only for setup or connection failures, not before every task:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" doctor
```

Inspect active Playwright sessions before cleanup:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" cleanup-plan
```

This skill controls only its `mychrome` session. Leave every other session that
`cleanup-plan` lists to the tool that owns it, and report it to the user. Let
ChatGPT browser control, ChromeDriver, and other test runners manage their own
Chrome processes. Never use this skill to run `close-all`, `kill-all`, or a
machine-wide Chrome kill.

Check an existing owned session without taking a new connection:

```bash
"$SKILL_ROOT/scripts/playwright-my-chrome.sh" ensure
```

`ensure` fails closed when the session is missing or stale. Only `connect`
performs a fresh attachment, and only after explicit user approval.

`connect` exits with status 3, before it attaches, when the Keychain token is
missing or does not match the extension token shape. The wrapper never prints
the stored value. If the stored value starts with
`PLAYWRIGHT_MCP_EXTENSION_TOKEN=`, a tool other than `store-extension-token.sh`
wrote it. This command strips the prefix and stores the token again in place:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh" \
  --migrate-from-service playwright-my-chrome.extension-token
```

For any other malformed or missing token, ask the user to regenerate and copy
it from the extension, then run:

```bash
"$SKILL_ROOT/scripts/store-extension-token.sh"
```

If **Allow & select** appears despite a stored token, stop immediately. The Keychain token
is stale or belongs to another Chrome profile. Ask the user to regenerate,
copy, and store it; do not wait silently or attempt to read extension storage.

If the helper page appears on every approved connection, run `doctor`. A
`missing` or `stale` session indicates that Chrome, the extension, or the daemon
is disconnecting between commands. Do not loop on `connect`. If the helper page
remains visible after one fresh connection, report the cleanup failure rather than
treating it as a requested tab.

Do not use the Chrome remote-debugging checkbox, `attach --cdp`, another browser
tool, AppleScript, or a different browser unless the user explicitly authorizes
that fallback.

## Security

- Never print, log, return, or screenshot the extension token.
- Never store it in this skill, shell profiles, repositories, `.env` files, or
  terminal history.
- Never ask the user to paste it into chat, a file, or a command.
- Playwright CLI passes the extension token in a Chrome connection URL during
  attachment. If Chrome is not already running, that URL can persist in the
  long-lived Chrome process command line. The wrapper checks the complete
  normal Chrome PID set immediately before and after attachment, detaches on
  any change, and requires token rotation if the token appears in a persistent
  process.
- The upstream Playwright CLI daemon inherits the token-bearing attachment
  environment while the owned session is alive. Processes running as the same
  macOS user may be able to inspect it. Disconnect after use and prefer a
  separate Chrome profile for higher-risk automation.
- Keep Node.js, npm, and the private runtime directory under the desktop
  user's control. `setup` installs the CLI only from the lockfile's integrity
  hashes and runs no package install scripts. The wrapper does not use `PATH`
  shims for secret-bearing system operations.
- To revoke this skill's stored-token access, delete the configured Keychain
  item and regenerate the extension token:

```bash
security delete-generic-password \
  -a "${PLAYWRIGHT_MY_CHROME_KEYCHAIN_ACCOUNT:-$(id -un)}" \
  -s "${PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE:-playwright-my-chrome.extension-token}"
```

If `doctor` reports `process-token: exposed`, complete all of these steps:

1. Disconnect the owned session.
2. Fully close normal Chrome so the token-bearing command line disappears.
3. While Chrome is closed, record a private, hash-only comparison baseline:

   ```bash
   "$SKILL_ROOT/scripts/playwright-my-chrome.sh" begin-token-rotation
   ```

4. Reopen Chrome manually and regenerate the token from the extension icon.
5. Copy it with the extension button and immediately run
   `"$SKILL_ROOT/scripts/store-extension-token.sh"`.
6. Mark the current Chrome process as the one in which regeneration occurred:

   ```bash
   "$SKILL_ROOT/scripts/playwright-my-chrome.sh" mark-token-regenerated
   ```

7. Fully quit and manually reopen Chrome again. This post-regeneration restart
   invalidates any client authorized with the previous token.
8. Verify the stored token changed and Chrome restarted without displaying
   either token:

   ```bash
   "$SKILL_ROOT/scripts/playwright-my-chrome.sh" rotation-status
   ```

9. Require `rotation: VERIFIED`, `token: stored`, and
   `process-token: absent` before reconnecting.
