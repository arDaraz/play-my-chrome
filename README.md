# Play My Chrome

[![CI](https://github.com/arDaraz/play-my-chrome/actions/workflows/ci.yml/badge.svg)](https://github.com/arDaraz/play-my-chrome/actions/workflows/ci.yml)

Control installed Google Chrome on a private, persistent profile through
Puppeteer. The skill launches Chrome over `--remote-debugging-pipe`, so it opens
no debugging port and needs no extension, token, or Chrome setting.

The private profile keeps its logins and cookies between sessions. Your normal
Chrome profile stays untouched, and your normal Chrome can stay open.

## Requirements

- Use macOS and Google Chrome installed in `/Applications`.
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

## Sign in and connect

The agent runs setup once to install the locked `puppeteer-core` dependency.
That package does not download Chrome. Then sign in to the sites the agent
needs, once:

```bash
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh setup
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh login https://accounts.example.test
```

`login` opens a visible Chrome window on the private profile with no debugging
channel. Sign in, then quit that Chrome with Cmd+Q. Closing only the window
leaves Chrome running on macOS, and the profile stays in use.

Ask your agent to use `$play-my-chrome` for the browser task. The agent runs
`connect`, which launches headless Chrome on the same profile:

```bash
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh connect
```

Use `tab-new` for a new task tab, or `tab-list` and `tab-select <id>` for a
listed tab. Run `--help` for the browser commands. The `run` command accepts a
local module with a default async function that receives Puppeteer's `page`.
See [the skill instructions](skills/play-my-chrome/SKILL.md) for an example.

Commands share one private session. `disconnect` closes the skill's Chrome and
keeps the profile's stored data:

```bash
~/.agents/skills/play-my-chrome/scripts/play-my-chrome.sh disconnect
```

## Profile location

The profile defaults to `~/Library/Application Support/play-my-chrome/chrome-profile`.
Set `PLAY_MY_CHROME_PROFILE_DIR` to another absolute path to use a different
one. The skill creates the directory with mode 0700 and an ownership marker. It
refuses a non-empty directory that it did not create, and any path inside the
normal Chrome user data directory. Only one Chrome can use the profile at a
time, so `connect` and `login` refuse while another Chrome holds it.

## Access

The private profile can hold any login you add with `login`. An agent that uses
the skill acts with those signed-in permissions. Add only the logins the agent
needs. A trusted `run` script can access Puppeteer's full browser API.
`tab-close` closes only a tab the skill created during the current session.

## Troubleshooting

Run the wrapper with `doctor` when setup or connection fails.

| Report | Action |
| --- | --- |
| Puppeteer missing or changed | Run `setup`. |
| Chrome not installed | Install Google Chrome in `/Applications`. |
| Profile in use | Quit the Chrome that uses the private profile, usually the `login` window. |
| Session missing | Run `connect`. |
| Older session active | Run `disconnect`, then `setup` and `connect`. |
| A site asks for a login | Run `disconnect`, then `login <url>`, sign in, and quit that Chrome. |
| Unsafe directory or socket | Correct the path or ownership. Keep private permissions. |

Setup requires a disconnected session. Locked packages install privately under
`~/Library/Caches/play-my-chrome/cli` with `npm ci --ignore-scripts`.
Global Playwright and Puppeteer installations are not used or changed.

## Migration

Install this version and use `$play-my-chrome`. It no longer attaches to your
normal Chrome, so you can turn off `chrome://inspect/#remote-debugging`. Run
`login` once for each site the agent needs. After verifying it works, remove
the old `playwright-my-chrome` skill from agent discovery. The runtime never
reads the old Keychain token or uses the Playwright Extension.

## Development

Run `npm run verify` for static validation and tests. Tests use fake browsers
and temporary local sockets. They do not use personal profiles or credentials.
See [CONTRIBUTING.md](CONTRIBUTING.md) for installation and live checks.

## Sources

- [Puppeteer launch options](https://pptr.dev/api/puppeteer.launchoptions).
- [Chrome remote debugging switch changes](https://developer.chrome.com/blog/remote-debugging-port).

## License

[MIT](LICENSE). Puppeteer and Chrome belong to their respective owners.
This project is independent of Google.
