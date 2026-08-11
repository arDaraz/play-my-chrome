# Playwright My Chrome

[![CI](https://github.com/arDaraz/playwright-my-chrome/actions/workflows/ci.yml/badge.svg)](https://github.com/arDaraz/playwright-my-chrome/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#requirements)

Let your coding agent drive the Chrome you already have open and signed in.

No new browser window. No second login. The agent works inside your real
profile, so your cookies, your sessions, and your tabs are already there.

Most browser automation launches its own Chrome, which lands the agent on a
login page for a site you are already signed in to. This skill uses the browser
that is already on your screen.

It is an [Agent Skill](https://agentskills.io/) that wraps the official
Playwright CLI and the official Playwright Extension. If your Chrome is not
running, it stops and tells you. It never quietly swaps in a different browser,
which is the failure it exists to prevent.

**macOS and Google Chrome only.** See [Requirements](#requirements).

> [!WARNING]
> A connected agent can read and control every tab that the Playwright
> Extension exposes, including websites you are signed in to. Install this only
> for agents and repositories you trust.

## What it looks like

Ask your agent something like:

> Open my analytics dashboard in my Chrome and tell me which pages lost traffic
> this week.

The agent connects to the Chrome window that is already open, works in a new
tab, and reads the dashboard. Nobody has to log in again.

To let the agent work on a tab you already have open, drag that tab into the
green Playwright tab group in Chrome. Tabs outside that group stay private and
untouched.

## Requirements

The skill installs on any agent. Running the browser automation needs:

- macOS
- Google Chrome
- the official
  [Playwright Extension](https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm)
- Node.js 22.20 or newer
- `@playwright/cli` version 0.1.17
- Bash and the macOS Keychain
- an agent that runs as the same desktop user as Chrome

A cloud agent cannot reach the Chrome on your Mac. It has to run in your own
desktop session.

## Install

Install the Playwright CLI at the version this skill supports:

```bash
npm install -g @playwright/cli@0.1.17
```

Install the skill for Codex and Claude Code:

```bash
npx skills install arDaraz/playwright-my-chrome \
  --skill playwright-my-chrome \
  --global \
  --agent codex \
  --agent claude-code
```

Use `--agent '*'` instead of the two `--agent` lines to install it for every
agent the [Vercel Skills CLI](https://github.com/vercel-labs/skills) supports.
To look at the repository first without installing anything, add `--list`.

The repository follows the
[Agent Skills specification](https://agentskills.io/specification) and uses the
standard `skills/<name>/SKILL.md` layout. The Skills CLI knows where each agent
keeps its skills. The skill itself does not depend on Codex, Claude Code, or
any other vendor.

## One-time setup

Do this once per macOS user and Chrome profile.

1. Install the Playwright Extension in the Chrome profile you want the agent to
   use, and turn it on.
2. Open Chrome yourself.
3. Open the extension connection page. Press the circular arrow button to
   generate a new token, then press the copy button.
4. While the token is still on the clipboard, ask your agent to configure
   `$playwright-my-chrome`. You can also run the skill's
   `scripts/store-extension-token.sh` yourself.
5. Run `scripts/playwright-my-chrome.sh doctor`. It should say that the token
   is stored and the CLI version is supported.

Never paste the token into a chat or a terminal command. The setup script
checks it without printing it, saves it in the macOS Keychain, and clears the
clipboard when it succeeds.

## What it refuses to do

This skill holds a real token and drives a browser you are signed in to, so it
fails closed instead of guessing:

- Chrome has to be running already. The skill never opens Chrome for you.
- Exactly one normal Chrome process may be running. The skill compares the full
  process list before and after connecting. If it changed, the skill stops.
- If the token shows up in Chrome's own command line, the skill refuses to
  connect and asks you to generate a new one.
- Connecting gives up after 60 seconds. The skill then closes what it started,
  tries to detach the session, deletes leftover files, and tells you what
  failed.
- These commands are blocked: `open`, raw `attach`, `show`, browser install,
  `close-all`, and `kill-all`.
- Disconnecting only detaches. Your Chrome keeps running.
- Every agent shares one private session named `mychrome`.
- The token is read in two cases only: a connection you approved, and a token
  change you asked for.
- Startup output that carries the token is captured and cleaned before anything
  is passed on.

The full procedure the agent follows lives in
[`SKILL.md`](skills/playwright-my-chrome/SKILL.md).

## Troubleshooting

Run this first. It reports what is missing without showing the token:

```bash
scripts/playwright-my-chrome.sh doctor
```

| What it says | What to do |
| --- | --- |
| `chrome: missing` | Open Chrome yourself, then try again. |
| `chrome: ambiguous` | More than one Chrome is running. Quit the extra ones. |
| `token: missing` | Redo [One-time setup](#one-time-setup). |
| `session: missing` | Normal before the first connection. Approve a connect. |
| `session: stale` | The old connection died. Approve a new connect. |
| `compatibility: unsupported` | Install the CLI version the line asks for. |
| `process-token: exposed` | Generate a new token. See [SECURITY.md](SECURITY.md). |

To check that every safeguard is active:

```bash
scripts/playwright-my-chrome.sh safety-audit
```

## Development

Run the release checks on macOS:

```bash
/bin/bash tests/lint.sh
/bin/bash tests/run.sh
npx skills@1.5.21 install . --list
```

The tests use fake Keychain, process list, clipboard, and Playwright commands.
They never open or control your real browser.

## Contributing

Pull requests are welcome. Every change to a safeguard needs a regression test,
and no test may touch a real token, Keychain item, clipboard, or Chrome
profile. Read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Security

Read [SECURITY.md](SECURITY.md) before you install. Report vulnerabilities
privately through GitHub's security advisory workflow, not in a public issue.

One limit worth knowing up front: while a session is attached, the Playwright
CLI daemon keeps the extension token in its environment. Any process running as
the same macOS user may be able to read it. That is upstream behavior, not
something this wrapper adds, and it cannot be fixed here. Disconnect when you
are done, and use a separate Chrome profile for anything risky.

## License

[MIT](LICENSE). Playwright and Google Chrome are trademarks of their owners.
This project is independent. Microsoft and Google do not endorse it.
