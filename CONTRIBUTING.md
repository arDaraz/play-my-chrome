# Contributing

Run `npm ci --ignore-scripts`, then `npm run verify`. Node.js 22.20 or newer,
Python 3, and ShellCheck are required. Tests exercise fake browser behavior and
private local sockets without touching real Chrome profiles or credentials.

## Dependencies

The skill's only direct runtime dependency is `puppeteer-core`, pinned in
`skills/play-my-chrome/cli/package.json` and its lockfile. Regenerate the
lock with npm after changing the exact version. Check the pipe launch against
the installed Chrome before updating it.

## Installation checks

Use the repository's locked Skills CLI to list and copy-install the skill for
Codex, Claude Code, universal, and wildcard agent targets into temporary folders.
Confirm each copy includes the license, executable wrapper, runtime scripts,
manifest, and lockfile. CI runs these checks.

## Live checks

Install a fresh copy from the task worktree before a manual browser check:

```bash
npx skills install . --skill play-my-chrome --global \
  --agent codex --agent claude-code --copy --yes
```

Set `PLAY_MY_CHROME_PROFILE_DIR` to a temporary private directory, so the check
leaves your real private profile alone. Run the installed wrapper's `setup` and
`doctor`. Run `connect`, create a task tab, read its rendered content, and
disconnect. Confirm that no Chrome process uses the profile after disconnect.
Run `login`, confirm `connect` refuses while that window is open, and quit it.
Report a missing Chrome or an unfinished sign-in as a pending check.

## Changes

Add a regression test for every changed safeguard and bug fix. Keep the existing
private profile, pipe launch, and session contracts. Describe changed user behavior
and access limits in the pull request. Report security-sensitive findings
through [SECURITY.md](SECURITY.md).
