#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_NPM_LOG:?MOCK_NPM_LOG is required}"
mock_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$PWD/node_modules/@playwright/cli"

{
  printf 'cwd=%s\n' "$PWD"
  printf 'args=%s\n' "$*"
  printf 'path=%s\n' "$PATH"
  printf 'lock=%s\n' "$(/usr/bin/shasum -a 256 <package-lock.json | /usr/bin/awk '{ print $1 }')"
} >>"$log_file"

/bin/mkdir -p "$package_dir"
case "${MOCK_NPM_MODE:-stable}" in
  fail)
    echo "mock npm ci failed" >&2
    exit 31
    ;;
  hang)
    printf '%s\n' "$$" >"${MOCK_NPM_PID_FILE:?MOCK_NPM_PID_FILE is required}"
    trap 'exit 143' TERM
    while :; do
      :
    done
    ;;
esac

node -e '
  const fs = require("fs");
  const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
  for (const [location, entry] of Object.entries(lock.packages)) {
    if (!location) continue;
    fs.mkdirSync(location, { recursive: true });
    fs.writeFileSync(location + "/package.json", JSON.stringify({ version: entry.version }));
  }
'

# The wrapper runs this entry with node, like a real install. It reports the
# installed lock version unless a test sets MOCK_CLI_VERSION.
/bin/cat >"$package_dir/playwright-cli.js" <<SCRIPT
const { spawnSync } = require("child_process");
const lock = require(__dirname + "/../../../package-lock.json");
const env = {
  MOCK_CLI_VERSION: lock.packages["node_modules/@playwright/cli"].version,
  ...process.env,
};
const result = spawnSync("$mock_dir/mock-playwright-cli.sh", process.argv.slice(2), {
  env,
  stdio: "inherit",
});
process.exit(result.status === null ? 1 : result.status);
SCRIPT
