# Play My Chrome

[![CI](https://github.com/arDaraz/play-my-chrome/actions/workflows/ci.yml/badge.svg)](https://github.com/arDaraz/play-my-chrome/actions/workflows/ci.yml)

Control the Chrome you already have open and signed in, through Puppeteer and
Chrome's native remote debugging. The skill needs no extension or token.

Your tabs, cookies, and logins stay in your current Chrome profile. Chrome can
show a connection approval dialog. Click **Allow** to connect. The skill keeps
that connection alive between commands and never launches another browser.

## Requirements

- Use macOS and Google Chrome 144 or newer.
- Install Node.js 22.20 or newer with its bundled npm.
- Run the agent as the same desktop user as Chrome.
- Allow npm registry access during the first setup and dependency updates.

## Install

Install the `play-my-chrome` skill:

```bash
npx skills install arDaraz/play-my-chrome \
  --skill play-my-chrome --global --agent codex --agent claude-code
```

Use `--agent '*'` to install for every supported agent. If your installation path
differs from `~/.agents/skills/play-my-chrome`, use that path below.

## Connect

1. Open your normal Chrome.
2. Open `chrome://inspect/#remote-debugging` and enable remote debugging.
3. Ask your agent to use `$play-my-chrome` for the browser task.
4. Click **Allow** if Chrome requests a connection.

The agent runs setup once to install the locked `puppeteer-core` dependency.
That package does not download Chrome. To do setup yourself:

```bash
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh setup
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh connect
```

Use `tab-new` for a new task tab, or `tab-list` and `tab-select <id>` for a tab
already open. Run `--help` for the browser commands. The `run` command accepts a
local module with a default async function that receives Puppeteer's `page`.
See [the skill instructions](skills/play-my-chrome/SKILL.md) for an example.

Commands share one private connection. A Chrome restart or an explicit
`disconnect` ends it. Reconnect and allow Chrome's dialog when necessary.
You never need to generate, copy, store, or renew an extension token.

## Choose a profile

Tell the agent which profile to use, such as "Use my Work Chrome profile."
The wrapper lists profile names and directory IDs:

```bash
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh profile-list
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh connect --profile "Work"
```

Use the directory ID, such as `Profile 1`, if names repeat. Without `--profile`,
the skill uses Chrome's default profile. Each connection keeps its profile choice.
Disconnect before choosing another profile.

Chrome's native connection selects its default profile and has no documented
profile switch option. Select the requested profile in Chrome first. The skill
checks the default and verifies the actual connected profile. That check briefly
opens and closes its own `chrome://version` tab. A mismatch stops task commands.
Profile selection does not edit Chrome's settings or profile files.

## Access and disconnect

Chrome's native connection can report tabs across profiles, including signed-in
sites. Built-in commands filter tabs to the verified profile and check the tab
before an action. Use trusted agents. The old extension's tab group no longer
limits access. These wrapper checks do not restrict the underlying debugging
connection. A trusted `run` script can access Puppeteer's full browser API.

```bash
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh disconnect
```

Disconnect leaves Chrome and all tabs open. `tab-close` closes only a tab the
skill created during the current connection. The runtime rejects browser launch
and global browser cleanup commands.

## Troubleshooting

Run the wrapper with `doctor` when setup or connection fails.

| Report | Action |
| --- | --- |
| Puppeteer missing or changed | Run `setup`. |
| Native debugging unavailable | Enable `chrome://inspect/#remote-debugging` in Chrome 144 or newer. |
| Chrome missing or ambiguous | Open exactly one normal Chrome instance. |
| Session missing | Run `connect` and allow the Chrome dialog. |
| Older session active | Run `disconnect`, then `setup` and `connect`. |
| Connection timed out | Check Chrome's debugging setting and approval dialog before retrying. |
| Unsafe directory or socket | Correct the path or ownership. Keep private permissions. |

Setup requires a disconnected session. Locked packages install privately under
`~/Library/Caches/play-my-chrome/cli` with `npm ci --ignore-scripts`.
Global Playwright and Puppeteer installations are not used or changed.

## Migration from Playwright

Install this replacement skill and use `$play-my-chrome`. After verifying
it works, remove the old `playwright-my-chrome` skill from agent discovery.
The new runtime never reads the old Keychain token or uses the Playwright
Extension. Existing old credentials and old sessions remain under your control.

## Development

Run `npm run verify` for static validation and tests. Tests use fake browsers
and temporary local sockets. They do not use personal profiles or credentials.
See [CONTRIBUTING.md](CONTRIBUTING.md) for installation and live checks.

## Sources

- [Chrome's native connection setup](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/advanced-usage.md#automatically-connecting-to-a-running-chrome-instance).
- [Puppeteer connection options](https://pptr.dev/api/puppeteer.connectoptions).

## License

[MIT](LICENSE). Puppeteer and Chrome belong to their respective owners.
This project is independent of Google.
