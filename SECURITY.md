# Security policy

## Reporting a vulnerability

Use this repository's **Security → Report a vulnerability** flow. Please do not
open a public issue for a suspected token leak, a browser-control bypass,
command injection, or unsafe cleanup behavior.

Include the affected commit or release, your macOS and Chrome versions, your
Playwright CLI version, the steps to reproduce it, and whether a real extension
token was exposed. Never put a live extension token, cookie, or session secret
in the report.

## What this skill gives an agent

This skill hands a local coding agent real access. The scope is worth stating
plainly:

- The Playwright Extension can expose signed-in browser tabs and their content.
- The wrapper reads one extension token from macOS Keychain, and only when you
  approve a fresh connection or run token-rotation verification.
- Browser commands run with the permissions of the logged-in macOS user.
- The skill runs its own private copy of `@playwright/cli`, which its `setup`
  command installs from the npm registry.

The agent, the repository holding your task, Node.js and npm, the
`@playwright/cli` release pinned in the skill's lockfile, the Playwright
Extension, Chrome, and your macOS account are all trusted components.
This skill does not make an untrusted agent safe. If you would not give the
agent your browser, do not install it.

## What it defends against

- The token is never accepted as a command-line argument.
- Setup reads it from the clipboard, stores it in Keychain, and clears the
  clipboard afterwards.
- Secret-bearing operations use fixed macOS system executables, never a
  `PATH` entry a caller can point somewhere else.
- Runtime directories must be private, owned by the current user, not a
  symlink, and claimed by the wrapper.
- Cleanup metadata is replaced atomically, must be a private regular file, and
  can name only one direct child output directory.
- Browser launch and machine-wide cleanup commands are blocked.
- A fresh connection needs a normal Chrome process that is already running.
- Only one normal Chrome main process is allowed. The complete PID set is
  rechecked immediately before and after attachment.
- A changed PID set, or a Chrome process carrying the token, causes a
  fail-closed detach and requires token rotation.
- Attachment is limited to 60 seconds. On timeout the wrapper kills the exact
  CLI child and its direct descendants, tries a named-session detach, reports
  any detach failure instead of claiming success, removes the private
  artifacts, and requires token rotation.
- The skill pins one exact `@playwright/cli` version in a lockfile. `setup`
  installs it with `npm ci --ignore-scripts`, so npm checks every package
  against its integrity hash and runs no package install scripts.
- The wrapper never runs a global `playwright-cli`. It runs only the private
  copy in its runtime directory, through the resolved Node.js.
- The private CLI directory must be a real directory owned by the current user
  with mode 0700. Otherwise every command fails closed with exit status 6, and
  `setup` refuses to replace it.
- The wrapper uses the private copy only when its lockfile matches the shipped
  one byte for byte and every locked package is installed at its locked
  version.
- Development dependencies are exact and integrity-locked.

## What it cannot defend against

These are listed so nobody assumes they are covered:

- Any connected agent can do whatever you could do in the exposed tabs.
- Browser and extension vulnerabilities are outside this project's control.
- Anyone who can change the Node.js installation or the private runtime
  directory can replace the Playwright CLI and read the token handed to it
  during attachment.
- The upstream Playwright CLI daemon inherits the token-bearing environment for
  as long as the session is attached. Other processes running as the same macOS
  user may be able to inspect it. `disconnect` shortens that window. It cannot
  remove the upstream behavior.
- The process checks narrow the Chrome-launch race. They cannot make
  cross-process inspection atomic.
- macOS may show a Keychain authorization prompt, depending on your local
  policy.

Use a separate Chrome profile for higher-risk automation. If you suspect
exposure, disconnect, delete the Keychain item, and generate a new extension
token.

## Supported versions

Security fixes ship for the latest tagged release. Each release supports
exactly the `@playwright/cli` version recorded in
`skills/playwright-my-chrome/cli/package-lock.json`. `setup` installs that
version privately, with integrity checks and `--ignore-scripts`. Browser
commands fail closed when the private copy is missing or reports any other
version.
