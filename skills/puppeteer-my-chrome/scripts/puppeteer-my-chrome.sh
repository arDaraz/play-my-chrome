#!/usr/bin/env bash
set -euo pipefail
skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supported_node() {
  "$1" -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || (major === 22 && minor >= 20) ? 0 : 1)'
}
node_bin="${PUPPETEER_MY_CHROME_NODE:-}"
if [[ -z "$node_bin" ]]; then
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node "$HOME/.volta/bin/node" /opt/homebrew/bin/node /usr/local/bin/node; do
    if [[ -x "$candidate" ]] && supported_node "$candidate"; then
      node_bin="$candidate"
      break
    fi
  done
fi
if [[ "$node_bin" != /* || ! -x "$node_bin" ]]; then
  echo "Node.js 22.20 or newer is required. Set PUPPETEER_MY_CHROME_NODE to its trusted absolute path." >&2
  exit 2
fi
supported_node "$node_bin" || {
  echo "Node.js 22.20 or newer is required." >&2
  exit 2
}
exec "$node_bin" "$skill_root/scripts/cli.mjs" "$@"
