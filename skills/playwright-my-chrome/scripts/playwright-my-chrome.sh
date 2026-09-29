#!/usr/bin/env bash
set -euo pipefail
umask 077

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
session_name="${PLAYWRIGHT_MY_CHROME_SESSION:-mychrome}"
keychain_service="${PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE:-playwright-my-chrome.extension-token}"
keychain_account="${PLAYWRIGHT_MY_CHROME_KEYCHAIN_ACCOUNT:-$(/usr/bin/id -un)}"
test_mode="${PLAYWRIGHT_MY_CHROME_TEST_MODE:-0}"
security_bin="/usr/bin/security"
extension_connect_url="chrome-extension://mmlmfjhmonkocbjadbfplnigmagldckm/connect.html"
chrome_executable="${PLAYWRIGHT_MY_CHROME_EXECUTABLE:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ps_bin="/bin/ps"
mv_bin="/bin/mv"
attach_timeout_attempts=600
setup_timeout_attempts=6000
default_runtime_dir="$HOME/Library/Caches/playwright-my-chrome"
runtime_dir="${PLAYWRIGHT_MY_CHROME_RUNTIME_DIR:-$default_runtime_dir}"
while [[ "$runtime_dir" != "/" && "$runtime_dir" == */ ]]; do
  runtime_dir="${runtime_dir%/}"
done
lock_dir="$runtime_dir/ensure.lock"
sanitize_marker="$runtime_dir/needs-sanitize"
output_path_file="$runtime_dir/session-output-path"
token_rotation_baseline_file="$runtime_dir/token-rotation-baseline.sha256"
token_rotation_chrome_pid_file="$runtime_dir/token-rotation-chrome.pid"
runtime_claim="$runtime_dir/.playwright-my-chrome-runtime"
cli_manifest="$skill_dir/cli/package.json"
cli_lock="$skill_dir/cli/package-lock.json"
private_cli_dir="$runtime_dir/cli"
private_cli_entry="$private_cli_dir/node_modules/@playwright/cli/playwright-cli.js"
setup_command="\"$skill_dir/scripts/playwright-my-chrome.sh\" setup"
setup_staging_dir=""
displaced_cli_dir=""
npm_bin=""
lock_held=0
bounded_child_pid=""
attachment_requires_recovery=0
listed_tabs=""

if [[ "$test_mode" == "1" ]]; then
  security_bin="${PLAYWRIGHT_MY_CHROME_TEST_SECURITY_BIN:-$security_bin}"
  ps_bin="${PLAYWRIGHT_MY_CHROME_TEST_PS_BIN:-$ps_bin}"
  mv_bin="${PLAYWRIGHT_MY_CHROME_TEST_MV_BIN:-$mv_bin}"
  attach_timeout_attempts="${PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS:-$attach_timeout_attempts}"
  npm_bin="${PLAYWRIGHT_MY_CHROME_TEST_NPM_BIN:-}"
  setup_timeout_attempts="${PLAYWRIGHT_MY_CHROME_TEST_SETUP_TIMEOUT_ATTEMPTS:-$setup_timeout_attempts}"
elif [[ "$test_mode" != "0" ]]; then
  echo "ERROR: PLAYWRIGHT_MY_CHROME_TEST_MODE must be 0 or 1." >&2
  exit 1
fi
die() {
  echo "ERROR: $*" >&2
  exit 1
}

private_dir_is_valid() {
  [[ -d "$1" && ! -L "$1" && -O "$1" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$1")" == "700" ]]
}

[[ "$attach_timeout_attempts" =~ ^[1-9][0-9]*$ ]] ||
  die "The attach timeout must be a positive number of 100ms attempts."
[[ "$setup_timeout_attempts" =~ ^[1-9][0-9]*$ ]] ||
  die "The setup timeout must be a positive number of 100ms attempts."
[[ -n "$session_name" ]] || die "The session name cannot be empty."
[[ -n "$keychain_service" ]] || die "The Keychain service cannot be empty."
[[ -n "$keychain_account" ]] || die "The Keychain account cannot be empty."
[[ -n "$runtime_dir" ]] || die "The runtime directory cannot be empty."
[[ "$runtime_dir" == /* ]] ||
  die "The runtime directory must be an absolute path."
[[ "$runtime_dir" != "/" && "$runtime_dir" != "$HOME" ]] ||
  die "Refusing to use a broad directory as the runtime."
[[ "$security_bin" == /* && -x "$security_bin" ]] ||
  die "The configured macOS Keychain executable is unavailable."
[[ "$chrome_executable" == /* ]] ||
  die "The configured Google Chrome executable must be an absolute path."
if [[ "$test_mode" != "1" && ! -x "$chrome_executable" ]]; then
  die "Google Chrome is unavailable at: $chrome_executable"
fi
[[ "$ps_bin" == /* && -x "$ps_bin" ]] ||
  die "The configured process-list executable is unavailable."
[[ "$mv_bin" == /* && -x "$mv_bin" ]] ||
  die "The configured move executable is unavailable."

if [[ "$(<"$cli_manifest")" =~ \"node\":[[:space:]]*\"\>=([0-9]+\.[0-9]+\.[0-9]+)\" ]]; then
  minimum_node_version="${BASH_REMATCH[1]}"
else
  echo "ERROR: The skill's cli/package.json is missing or has no Node.js engines minimum: $cli_manifest" >&2
  echo "Reinstall the skill. No browser command was attempted." >&2
  exit 2
fi

version_at_least() {
  local have_major=""
  local have_minor=""
  local have_patch=""
  local need_major=""
  local need_minor=""
  local need_patch=""

  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r have_major have_minor have_patch <<<"$1"
  IFS=. read -r need_major need_minor need_patch <<<"$2"
  if (( have_major != need_major )); then
    (( have_major > need_major ))
  elif (( have_minor != need_minor )); then
    (( have_minor > need_minor ))
  else
    (( have_patch >= need_patch ))
  fi
}

node_version_of() {
  "$1" -p 'process.versions.node' 2>/dev/null || true
}

configured_node() {
  local candidate="$PLAYWRIGHT_MY_CHROME_NODE"
  local version=""

  if [[ "$candidate" != /* || ! -x "$candidate" ]]; then
    echo "ERROR: PLAYWRIGHT_MY_CHROME_NODE must be an absolute path to Node.js: $candidate" >&2
    return 1
  fi
  version="$(node_version_of "$candidate")"
  if ! version_at_least "$version" "$minimum_node_version"; then
    echo "ERROR: Node.js ${version:-unknown} is older than the required $minimum_node_version: $candidate" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

# nvm names each install after its version, so this function skips old
# versions without running them.
newest_qualifying_nvm_node() {
  local candidate=""
  local newest=""
  local version=""

  shopt -s nullglob
  for candidate in "$HOME"/.nvm/versions/node/v*/bin/node; do
    version="${candidate%/bin/node}"
    version_at_least "${version##*/v}" "$minimum_node_version" || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
      newest="$candidate"
    fi
  done
  shopt -u nullglob
  printf '%s' "$newest"
}

resolve_node() {
  local candidate=""
  local candidates=()
  local newest_nvm_node=""

  if [[ -n "${PLAYWRIGHT_MY_CHROME_NODE:-}" ]]; then
    configured_node
    return
  fi

  newest_nvm_node="$(newest_qualifying_nvm_node)"
  [[ -z "$newest_nvm_node" ]] || candidates+=("$newest_nvm_node")
  candidates+=("$HOME/.volta/bin/node" /opt/homebrew/bin/node /usr/local/bin/node)
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    if version_at_least "$(node_version_of "$candidate")" "$minimum_node_version"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "ERROR: No Node.js $minimum_node_version or newer was found in nvm, Volta, Homebrew, or /usr/local." >&2
  return 1
}

node_bin="$(resolve_node)" || exit 1
[[ -n "$npm_bin" ]] || npm_bin="${node_bin%/*}/npm"
cli_command=("$node_bin" "$private_cli_entry")

supported_cli_version="$(
  "$node_bin" -e '
    const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(lock.packages["node_modules/@playwright/cli"].version);
  ' "$cli_lock" 2>/dev/null
)" || supported_cli_version=""
if [[ ! "$supported_cli_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: The skill's Playwright CLI lockfile is missing or unreadable: $cli_lock" >&2
  echo "Reinstall the skill. No browser command was attempted." >&2
  exit 2
fi

if [[ -L "$runtime_dir" ]]; then
  die "The runtime cannot be a symbolic link: $runtime_dir"
fi
if [[ -e "$runtime_dir" && ! -d "$runtime_dir" ]]; then
  die "The runtime is not a directory: $runtime_dir"
fi
if [[ ! -d "$runtime_dir" ]] && ! /bin/mkdir -p "$runtime_dir"; then
  die "Could not create the private Playwright runtime: $runtime_dir"
fi
[[ -O "$runtime_dir" ]] ||
  die "The private Playwright runtime is not owned by the current user."
[[ "$(/usr/bin/stat -f '%Lp' "$runtime_dir")" == "700" ]] ||
  die "The private Playwright runtime must have mode 0700: $runtime_dir"

if [[ -L "$runtime_claim" ]]; then
  die "The runtime claim cannot be a symbolic link."
fi
if [[ -e "$runtime_claim" && ! -f "$runtime_claim" ]]; then
  die "The runtime claim is not a regular file."
fi
if [[ ! -f "$runtime_claim" ]]; then
  if [[ "$runtime_dir" != "$default_runtime_dir" ]] &&
    [[ -n "$(/usr/bin/find "$runtime_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "Refusing to claim a non-empty custom runtime directory."
  fi
  printf '%s\n' "playwright-my-chrome-runtime-v1" >"$runtime_claim" ||
    die "Could not claim the private Playwright runtime."
fi
[[ -O "$runtime_claim" ]] ||
  die "The runtime claim is not owned by the current user."
[[ "$(/usr/bin/stat -f '%Lp' "$runtime_claim")" == "600" ]] ||
  die "The runtime claim must have mode 0600."
IFS= read -r runtime_claim_value <"$runtime_claim" ||
  die "Could not read the runtime claim."
[[ "$runtime_claim_value" == "playwright-my-chrome-runtime-v1" ]] ||
  die "The runtime claim is invalid."
unset runtime_claim_value

if [[ -L "$runtime_dir/.playwright" ]]; then
  die "The Playwright workspace marker cannot be a symbolic link."
fi
if [[ -e "$runtime_dir/.playwright" && ! -d "$runtime_dir/.playwright" ]]; then
  die "The Playwright workspace marker is not a directory."
fi
if [[ ! -d "$runtime_dir/.playwright" ]] &&
  ! /bin/mkdir "$runtime_dir/.playwright"; then
  die "Could not create the private Playwright workspace."
fi
[[ -O "$runtime_dir/.playwright" ]] ||
  die "The private Playwright workspace is not owned by the current user."
[[ "$(/usr/bin/stat -f '%Lp' "$runtime_dir/.playwright")" == "700" ]] ||
  die "The private Playwright workspace must have mode 0700."

# This check exits 6, not 2, because setup cannot repair a replaced CLI
# directory and the CLI receives the token.
if [[ -e "$private_cli_dir" || -L "$private_cli_dir" ]] &&
  ! private_dir_is_valid "$private_cli_dir"; then
  echo "SECURITY: The private Playwright CLI must be a directory you own with mode 0700, not a symbolic link: $private_cli_dir" >&2
  echo "Inspect and remove it, then run setup. No browser command was attempted." >&2
  exit 6
fi

# All secret-bearing processing below uses resolved executables plus trusted
# macOS system utilities rather than caller-controlled PATH shims.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# Playwright CLI picks its daemon session from the nearest .playwright folder.
# The wrapper always runs inside its own private workspace folder.
# The mychrome session then stays the same in every repository.
run_cli() {
  (
    cd "$runtime_dir"
    NO_UPDATE_NOTIFIER=1 "${cli_command[@]}" "$@"
  )
}

is_allowed_state_file() {
  case "$1" in
    "$output_path_file"|"$sanitize_marker"|"$token_rotation_baseline_file"|"$token_rotation_chrome_pid_file")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

private_state_file_is_valid() {
  local file="$1"

  is_allowed_state_file "$file" || return 1
  [[ -f "$file" && ! -L "$file" && -O "$file" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$file")" == "600" ]]
}

write_private_state_file() {
  local target="$1"
  local value="$2"
  local temporary=""

  is_allowed_state_file "$target" || return 1
  temporary="$(/usr/bin/mktemp "$runtime_dir/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" >"$temporary"; then
    /bin/rm -f "$temporary"
    return 1
  fi
  if ! "$node_bin" -e '
    const fs = require("fs");
    fs.renameSync(process.argv[1], process.argv[2]);
  ' "$temporary" "$target"; then
    /bin/rm -f "$temporary"
    return 1
  fi
  private_state_file_is_valid "$target"
}

remove_private_state_file() {
  local target="$1"

  is_allowed_state_file "$target" || return 1
  /bin/rm -f "$target"
}

cli_entry_version() {
  run_bounded_impl "" 80 "$runtime_dir" \
    env NO_UPDATE_NOTIFIER=1 "$node_bin" "$1" --version 2>/dev/null |
    awk 'NR == 1 { print $1; exit }'
}

# Prints the locked @playwright/cli version only when every locked package is
# installed at its locked version.
installed_lock_cli_version() {
  "$node_bin" -e '
    const fs = require("fs");
    const path = require("path");
    const root = process.argv[1];
    const read = file => JSON.parse(fs.readFileSync(path.join(root, file), "utf8"));
    const lock = read("package-lock.json");
    for (const [location, entry] of Object.entries(lock.packages)) {
      if (!location || entry.dev) continue;
      const manifest = path.join(location, "package.json");
      if (entry.optional && !fs.existsSync(path.join(root, manifest))) continue;
      if (read(manifest).version !== entry.version) process.exit(1);
    }
    process.stdout.write(lock.packages["node_modules/@playwright/cli"].version);
  ' "$1" 2>/dev/null
}

# The fault functions print why a CLI copy is unusable, or nothing.
intact_cli_fault() {
  local cli_dir="$1"
  local entry="$cli_dir/node_modules/@playwright/cli/playwright-cli.js"
  local locked_version=""
  local version=""

  if [[ ! -f "$entry" ]]; then
    echo "is not installed"
  elif ! locked_version="$(installed_lock_cli_version "$cli_dir")"; then
    echo "is incomplete or was changed after setup"
  else
    version="$(cli_entry_version "$entry" || true)"
    if [[ "$version" != "$locked_version" ]]; then
      echo "reports version ${version:-unknown}, not its locked $locked_version"
    fi
  fi
}

supported_cli_fault() {
  local fault=""

  fault="$(intact_cli_fault "$private_cli_dir")"
  if [[ -z "$fault" ]] &&
    ! /usr/bin/cmp -s "$cli_lock" "$private_cli_dir/package-lock.json"; then
    fault="was installed from another skill release's lockfile"
  fi
  printf '%s' "$fault"
}

require_usable_cli() {
  local fault="$1"

  [[ -z "$fault" ]] && return 0
  echo "The skill's private Playwright CLI $fault." >&2
  echo "This release requires @playwright/cli $supported_cli_version. Install it with:" >&2
  echo "  $setup_command" >&2
  echo "No browser command was attempted." >&2
  return 2
}

remove_setup_staging() {
  if [[ -n "$displaced_cli_dir" && -e "$displaced_cli_dir" && ! -e "$private_cli_dir" ]]; then
    "$mv_bin" "$displaced_cli_dir" "$private_cli_dir" ||
      echo "Could not restore the previous private Playwright CLI." >&2
  fi
  displaced_cli_dir=""
  if [[ -n "$setup_staging_dir" ]]; then
    /bin/rm -rf "$setup_staging_dir"
    setup_staging_dir=""
  fi
}

remove_abandoned_setup_staging() {
  local abandoned=""

  shopt -s nullglob
  for abandoned in "$runtime_dir"/.cli-setup.*; do
    if private_dir_is_valid "$abandoned"; then
      /bin/rm -rf "$abandoned"
    else
      echo "WARNING: Left an unexpected setup path in place: $abandoned" >&2
    fi
  done
  shopt -u nullglob
}

owned_session_attachment() {
  local payload=""

  if ! payload="$(run_cli_bounded 80 --json list 2>/dev/null)"; then
    printf '%s\n' "unknown"
    return 0
  fi
  printf '%s' "$payload" |
    "$node_bin" -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", chunk => input += chunk);
      process.stdin.on("end", () => {
        try {
          const browser = (JSON.parse(input).browsers || []).find(
            item => item.name === process.argv[1]
          );
          process.stdout.write(browser && browser.attached === true ? "attached\n" : "detached\n");
        } catch {
          process.stdout.write("unknown\n");
        }
      });
    ' "$session_name"
}

# Paths go through the environment, not argv, so this pipeline cannot match
# itself. Only node running a private-copy script counts.
private_cli_process_pids() {
  local physical_cli_dir=""

  physical_cli_dir="$(cd -P "$runtime_dir" && pwd -P)/cli" || return 1
  "$ps_bin" -axo pid=,command= |
    PRIVATE_CLI_LOGICAL="$private_cli_dir/node_modules/" \
      PRIVATE_CLI_PHYSICAL="$physical_cli_dir/node_modules/" \
      RESOLVED_NODE="$node_bin" \
      awk '
        function runs_private_script(command, prefix,    position, executable) {
          position = index(command, " " prefix)
          if (position == 0)
            return 0
          executable = substr(command, 1, position - 1)
          return executable == ENVIRON["RESOLVED_NODE"] || executable == "node" || executable ~ /\/node$/
        }
        {
          pid = $1
          command = $0
          sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
          if (runs_private_script(command, ENVIRON["PRIVATE_CLI_LOGICAL"]) ||
            runs_private_script(command, ENVIRON["PRIVATE_CLI_PHYSICAL"]))
            print pid
        }
      '
}

# Disconnect needs a working copy. When a damaged copy cannot report its
# session, setup refuses only while a process runs from it.
require_detached_session() {
  local attachment=""
  local pids=""

  attachment="$(owned_session_attachment)"
  if [[ "$attachment" == "detached" ]]; then
    return 0
  fi
  if [[ "$attachment" == "attached" ]]; then
    echo "Session '$session_name' is attached through the current private Playwright CLI." >&2
    echo "Run 'disconnect' first, then run setup again. Setup never detaches on its own." >&2
    return 1
  fi
  pids="$(private_cli_process_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  [[ -z "$pids" ]] && return 0
  echo "The private CLI cannot report session '$session_name', and a Playwright daemon from the private CLI is still running (pid $pids)." >&2
  echo "Ask the user before stopping that process, then run setup again. Setup never stops it on its own." >&2
  return 1
}

stage_private_cli() {
  local staged_cli="$1"
  local fault=""
  local status=0

  /bin/mkdir "$staged_cli" || return 1
  /bin/cp "$cli_manifest" "$cli_lock" "$staged_cli/" || return 1
  run_bounded_impl "" "$setup_timeout_attempts" "$staged_cli" \
    env PATH="${node_bin%/*}:$PATH" NO_UPDATE_NOTIFIER=1 "$npm_bin" ci \
    --ignore-scripts --omit=dev --no-audit --no-fund || status=$?
  if (( status == 124 )); then
    echo "npm ci timed out; no private Playwright CLI was installed." >&2
    return 1
  elif (( status != 0 )); then
    echo "npm ci failed; no private Playwright CLI was installed." >&2
    return 1
  fi

  fault="$(intact_cli_fault "$staged_cli")"
  if [[ -n "$fault" ]]; then
    echo "The installed Playwright CLI $fault." >&2
    echo "No private Playwright CLI was installed." >&2
    return 1
  fi
}

# remove_setup_staging moves the displaced copy back if the new copy never
# reached its place, including after an interrupt.
replace_private_cli() {
  local staged_cli="$1"

  if [[ -e "$private_cli_dir" ]]; then
    displaced_cli_dir="$setup_staging_dir/previous"
    "$mv_bin" "$private_cli_dir" "$displaced_cli_dir" || return 1
  fi
  "$mv_bin" "$staged_cli" "$private_cli_dir" || return 1
  displaced_cli_dir=""
}

install_private_cli() {
  remove_abandoned_setup_staging
  if [[ -z "$(supported_cli_fault)" ]]; then
    echo "@playwright/cli $supported_cli_version is already installed at $private_cli_dir."
    return 0
  fi
  require_detached_session || return 1
  if [[ "$npm_bin" != /* || ! -x "$npm_bin" ]]; then
    echo "npm was not found next to Node.js: $npm_bin" >&2
    return 1
  fi

  setup_staging_dir="$(/usr/bin/mktemp -d "$runtime_dir/.cli-setup.XXXXXX")" ||
    return 1
  stage_private_cli "$setup_staging_dir/cli" || return 1
  replace_private_cli "$setup_staging_dir/cli" || return 1
  echo "Installed @playwright/cli $supported_cli_version at $private_cli_dir."
}

setup_private_cli() {
  local status=0

  acquire_lock || return 1
  install_private_cli || status=$?
  remove_setup_staging
  release_lock
  return "$status"
}

run_cli_redacted() {
  local statuses=()

  set +e
  run_cli "$@" 2>&1 |
    sed -E \
      "s#(${extension_connect_url//./\\.})\\?[^\\\")[:space:]]*#\\1?<redacted>#g"
  statuses=("${PIPESTATUS[@]}")
  set -e
  return "${statuses[0]}"
}

terminate_bounded_process() {
  local attempt=0
  local child_pid="$1"
  local descendant_pid=""
  local descendant_pids=""
  local running=0

  [[ "$child_pid" =~ ^[0-9]+$ ]] || return 0
  descendant_pids="$(/usr/bin/pgrep -P "$child_pid" 2>/dev/null || true)"
  for descendant_pid in $descendant_pids; do
    [[ "$descendant_pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$descendant_pid" 2>/dev/null || true
  done
  kill -TERM "$child_pid" 2>/dev/null || true

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    running=0
    kill -0 "$child_pid" 2>/dev/null && running=1
    for descendant_pid in $descendant_pids; do
      [[ "$descendant_pid" =~ ^[0-9]+$ ]] || continue
      kill -0 "$descendant_pid" 2>/dev/null && running=1
    done
    (( running == 0 )) && break
    sleep 0.1
  done

  for descendant_pid in $descendant_pids; do
    [[ "$descendant_pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$descendant_pid" 2>/dev/null; then
      kill -KILL "$descendant_pid" 2>/dev/null || true
    fi
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  wait "$child_pid" 2>/dev/null || true
}

terminate_active_bounded_child() {
  local child_pid="$bounded_child_pid"

  bounded_child_pid=""
  terminate_bounded_process "$child_pid"
}

run_bounded_impl() {
  local attempt=0
  local child_pid=""
  local max_attempts="${2:?missing timeout attempts}"
  local output_file="$1"
  local status=0
  local work_dir="${3:?missing working directory}"
  shift 3

  if [[ -n "$output_file" ]]; then
    (
      cd "$work_dir"
      exec "$@"
    ) >"$output_file" 2>&1 &
  else
    (
      cd "$work_dir"
      exec "$@"
    ) &
  fi
  child_pid=$!
  bounded_child_pid="$child_pid"

  while kill -0 "$child_pid" 2>/dev/null; do
    if (( attempt >= max_attempts )); then
      terminate_active_bounded_child
      return 124
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done

  if wait "$child_pid"; then
    status=0
  else
    status=$?
  fi
  bounded_child_pid=""
  return "$status"
}

run_cli_bounded() {
  local max_attempts="${1:?missing timeout attempts}"
  shift

  run_bounded_impl "" "$max_attempts" "$runtime_dir" \
    env NO_UPDATE_NOTIFIER=1 "${cli_command[@]}" "$@"
}

run_cli_bounded_to_file() {
  local max_attempts="${2:?missing timeout attempts}"
  local output_file="${1:?missing output file}"
  shift 2

  [[ "$output_file" == /* ]] || return 1
  run_bounded_impl "$output_file" "$max_attempts" "$runtime_dir" \
    env NO_UPDATE_NOTIFIER=1 "${cli_command[@]}" "$@"
}

read_token() {
  local token=""

  if [[ ! -x "$security_bin" ]]; then
    echo "macOS Keychain command 'security' is unavailable." >&2
    return 1
  fi

  token="$(
    "$security_bin" find-generic-password \
      -a "$keychain_account" \
      -s "$keychain_service" \
      -w 2>/dev/null || true
  )"

  if [[ ! "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]]; then
    echo "Playwright Extension token is missing or malformed in macOS Keychain." >&2
    echo "No browser connection was attempted." >&2
    echo "If it carries a copied PLAYWRIGHT_MCP_EXTENSION_TOKEN= prefix, repair it in place:" >&2
    echo "  $skill_dir/scripts/store-extension-token.sh --migrate-from-service $keychain_service" >&2
    echo "Otherwise regenerate and copy it in the extension, then run:" >&2
    echo "  $skill_dir/scripts/store-extension-token.sh" >&2
    return 1
  fi

  printf '%s' "$token"
}

token_is_stored() {
  [[ -x "$security_bin" ]] &&
    "$security_bin" find-generic-password \
      -a "$keychain_account" \
      -s "$keychain_service" >/dev/null 2>&1
}

current_token_digest() {
  local digest=""
  local token=""

  token="$(read_token)" || return 1
  digest="$(
    printf '%s' "$token" |
      /usr/bin/shasum -a 256 |
      awk '{ print $1 }'
  )"
  unset token
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

rotation_state() {
  local baseline=""
  local chrome_count=0
  local chrome_pid=""
  local chrome_pids=""
  local current=""
  local regeneration_pid=""
  local process_state=""

  if [[ ! -e "$token_rotation_baseline_file" &&
    ! -L "$token_rotation_baseline_file" ]]; then
    printf '%s\n' "not-started"
    return 0
  fi
  if ! private_state_file_is_valid "$token_rotation_baseline_file"; then
    printf '%s\n' "invalid-baseline"
    return 0
  fi
  IFS= read -r baseline <"$token_rotation_baseline_file" || {
    printf '%s\n' "invalid-baseline"
    return 0
  }
  if [[ ! "$baseline" =~ ^[a-f0-9]{64}$ ]]; then
    printf '%s\n' "invalid-baseline"
    return 0
  fi
  current="$(current_token_digest 2>/dev/null)" || {
    printf '%s\n' "token-missing"
    return 0
  }
  if [[ "$current" == "$baseline" ]]; then
    printf '%s\n' "pending"
    return 0
  fi
  if [[ ! -e "$token_rotation_chrome_pid_file" &&
    ! -L "$token_rotation_chrome_pid_file" ]]; then
    printf '%s\n' "regenerated-unmarked"
    return 0
  fi
  if ! private_state_file_is_valid "$token_rotation_chrome_pid_file"; then
    printf '%s\n' "invalid-regeneration-marker"
    return 0
  fi
  IFS= read -r regeneration_pid <"$token_rotation_chrome_pid_file" || {
    printf '%s\n' "invalid-regeneration-marker"
    return 0
  }
  if [[ ! "$regeneration_pid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "invalid-regeneration-marker"
    return 0
  fi
  process_state="$(persistent_extension_token_state)"
  if [[ "$process_state" != "absent" ]]; then
    printf '%s\n' "rotated-process-exposed"
    return 0
  fi
  chrome_pids="$(normal_chrome_pids)"
  chrome_count="$(printf '%s\n' "$chrome_pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( chrome_count == 0 )); then
    printf '%s\n' "awaiting-reopen"
  elif (( chrome_count > 1 )); then
    printf '%s\n' "ambiguous-chrome"
  else
    chrome_pid="$chrome_pids"
    if [[ "$chrome_pid" == "$regeneration_pid" ]]; then
      printf '%s\n' "awaiting-restart"
    else
      printf '%s\n' "verified"
    fi
  fi
}

rotation_metadata_state() {
  if [[ ! -e "$token_rotation_baseline_file" &&
    ! -L "$token_rotation_baseline_file" ]]; then
    printf '%s\n' "not started"
    return 0
  fi
  if ! private_state_file_is_valid "$token_rotation_baseline_file"; then
    printf '%s\n' "invalid private baseline"
    return 0
  fi
  if [[ -e "$token_rotation_chrome_pid_file" ||
    -L "$token_rotation_chrome_pid_file" ]] &&
    ! private_state_file_is_valid "$token_rotation_chrome_pid_file"; then
    printf '%s\n' "invalid private regeneration marker"
    return 0
  fi
  printf '%s\n' "in progress (run rotation-status to verify)"
}

begin_token_rotation() {
  local digest=""

  if [[ "$(persistent_extension_token_state)" != "absent" ]]; then
    echo "A token-bearing Chrome process is still running." >&2
    echo "Disconnect and fully close Chrome before beginning rotation." >&2
    return 1
  fi
  digest="$(current_token_digest)" || return 1
  if ! write_private_state_file "$token_rotation_baseline_file" "$digest"; then
    echo "Could not record the private token-rotation baseline." >&2
    return 1
  fi
  unset digest
  remove_private_state_file "$token_rotation_chrome_pid_file" || return 1
  echo "Token-rotation baseline recorded privately."
  echo "Regenerate and copy the extension token, then run store-extension-token.sh."
}

mark_token_regenerated() {
  local baseline=""
  local chrome_pid=""
  local current=""

  private_state_file_is_valid "$token_rotation_baseline_file" || {
    echo "Token rotation has not been started." >&2
    return 1
  }
  IFS= read -r baseline <"$token_rotation_baseline_file" || return 1
  current="$(current_token_digest)" || return 1
  if [[ "$current" == "$baseline" ]]; then
    echo "The stored extension token has not changed." >&2
    return 1
  fi
  chrome_pid="$(require_running_normal_chrome)" || return $?
  if ! write_private_state_file "$token_rotation_chrome_pid_file" "$chrome_pid"; then
    echo "Could not record the post-regeneration Chrome process." >&2
    return 1
  fi
  echo "Regenerated token recorded for Chrome pid $chrome_pid."
  echo "Fully restart Chrome manually; rotation remains incomplete until its pid changes."
}

token_rotation_status() {
  local state=""

  state="$(rotation_state)"
  echo "Playwright Extension token rotation"
  case "$state" in
    not-started)
      echo "rotation: not started"
      ;;
    pending)
      echo "rotation: pending (stored token has not changed)"
      ;;
    regenerated-unmarked)
      echo "rotation: regenerated token must be marked before restart"
      ;;
    awaiting-restart)
      echo "rotation: awaiting Chrome restart after regeneration"
      ;;
    awaiting-reopen)
      echo "rotation: awaiting Chrome reopen after regeneration"
      ;;
    ambiguous-chrome)
      echo "rotation: incomplete (multiple normal Chrome main processes are running)"
      ;;
    verified)
      echo "rotation: VERIFIED (token changed; Chrome restarted; process token absent)"
      if ! remove_private_state_file "$token_rotation_baseline_file" ||
        ! remove_private_state_file "$token_rotation_chrome_pid_file"; then
        echo "Could not clear completed token-rotation metadata." >&2
        return 1
      fi
      ;;
    rotated-process-exposed)
      echo "rotation: incomplete (stored token changed; process token exposed)"
      ;;
    token-missing)
      echo "rotation: incomplete (replacement token is not stored)"
      ;;
    invalid-baseline)
      echo "rotation: invalid private baseline"
      ;;
    invalid-regeneration-marker)
      echo "rotation: invalid private regeneration marker"
      ;;
    *)
      echo "rotation: unknown"
      return 1
      ;;
  esac
}

normal_chrome_pids() {
  "$ps_bin" -axo pid=,command= |
    awk -v executable="$chrome_executable" '
      {
        pid = $1
        $1 = ""
        sub(/^[[:space:]]+/, "")
        command = $0
        if (index(command, executable) != 1)
          next
        if (command ~ /--user-data-dir=/)
          next
        if (command ~ /--remote-debugging-(pipe|port)/)
          next
        if (command ~ /--headless([=[:space:]]|$)/)
          next
        if (command ~ /--enable-automation([=[:space:]]|$)/)
          next
        if (command ~ /--test-type=webdriver([=[:space:]]|$)/)
          next
        if (command ~ /--no-startup-window([=[:space:]]|$)/)
          next
        print pid
      }
    ' |
    /usr/bin/sort -n -u
}

require_running_normal_chrome() {
  local count=0
  local pid=""
  local pids=""

  pids="$(normal_chrome_pids)"
  count="$(printf '%s\n' "$pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( count == 1 )); then
    pid="$pids"
    printf '%s\n' "$pid"
    return 0
  fi
  if (( count > 1 )); then
    echo "Multiple normal Google Chrome main processes are running." >&2
    echo "No extension connection was attempted because browser ownership is ambiguous." >&2
    echo "Fully quit the extra Chrome instances, then run 'connect' again." >&2
    return 5
  fi

  echo "Normal user Chrome is not already running." >&2
  echo "No browser was launched and no extension connection was attempted." >&2
  echo "Open Google Chrome manually in the signed-in profile, then run 'connect' again." >&2
  return 5
}

persistent_extension_token_state() {
  if "$ps_bin" -axo command= |
    awk -v executable="$chrome_executable" -v connect_url="$extension_connect_url" '
      index($0, executable) == 1 &&
      index($0, connect_url) > 0 &&
      $0 ~ /[?&]token=[A-Za-z0-9_-]+/ {
        found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '; then
    printf '%s\n' "exposed"
  else
    printf '%s\n' "absent"
  fi
}

session_state_once() {
  local payload=""

  if ! payload="$(run_cli_bounded 80 --json list 2>/dev/null)"; then
    printf '%s\n' "unavailable"
    return 0
  fi

  printf '%s' "$payload" |
    "$node_bin" -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", chunk => input += chunk);
      process.stdin.on("end", () => {
        try {
          const payload = JSON.parse(input);
          const browser = (payload.browsers || []).find(
            item => item.name === process.argv[1]
          );
          if (!browser) {
            process.stdout.write("missing\n");
          } else if (
            browser.status === "open" &&
            browser.attached === true &&
            browser.compatible !== false
          ) {
            process.stdout.write("ready\n");
          } else {
            process.stdout.write("stale\n");
          }
        } catch {
          process.stdout.write("unavailable\n");
        }
      });
    ' "$session_name"
}

session_state() {
  local attempt=0
  local state=""

  while (( attempt < 3 )); do
    state="$(session_state_once)"
    if [[ "$state" != "unavailable" ]]; then
      printf '%s\n' "$state"
      return 0
    fi
    attempt=$((attempt + 1))
    (( attempt < 3 )) && sleep 0.1
  done

  printf '%s\n' "unavailable"
}

conflicting_attached_chrome_sessions() {
  local payload=""
  local result=""

  payload="$(run_cli_bounded 80 --json list --all 2>/dev/null)" || return 2
  result="$(
    printf '%s' "$payload" |
      "$node_bin" -e '
        let input = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", chunk => input += chunk);
        process.stdin.on("end", () => {
          try {
            const payload = JSON.parse(input);
            const conflicts = (payload.browsers || []).filter(browser =>
              browser.status === "open" &&
              browser.attached === true &&
              !(
                browser.workspace === process.argv[2] &&
                browser.name === process.argv[1]
              ) &&
              (
                browser.name === process.argv[1] ||
                browser.browserType === "chrome"
              )
            );
            process.stdout.write(
              conflicts
                .map(browser =>
                  browser.name + " (" + browser.workspace + ")"
                )
                .join("\n")
            );
          } catch {
            process.exitCode = 2;
          }
        });
      ' "$session_name" "$runtime_dir"
  )" || return 2

  printf '%s' "$result"
}

list_tabs() {
  local attempt=0
  local tabs=""

  while (( attempt < 3 )); do
    if tabs="$(
      run_cli_bounded 80 --raw -s="$session_name" tab-list 2>/dev/null
    )"; then
      printf '%s\n' "$tabs"
      return 0
    fi
    attempt=$((attempt + 1))
    (( attempt < 3 )) && sleep 0.1
  done

  return 1
}

list_tabs_guarded() {
  local attempt=0
  local output_file="${1:?missing guarded tab output file}"
  local output_dir="${output_file%/*}"

  [[ "$output_file" == "$output_dir/tabs.log" ]] || return 1
  output_directory_is_valid "$output_dir" || return 1
  listed_tabs=""
  while (( attempt < 3 )); do
    if run_cli_bounded_to_file "$output_file" 80 --raw \
      -s="$session_name" tab-list; then
      listed_tabs="$(<"$output_file")"
      return 0
    fi
    attempt=$((attempt + 1))
    (( attempt < 3 )) && sleep 0.1
  done

  return 1
}

helper_tab_line() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      {
        # Playwright renders each tab as Markdown. Inspect only the final URL
        # field so a hostile page title containing the helper URL cannot be
        # mistaken for the extension helper.
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url == needle || index(url, needle "?") == 1) {
          print
          exit
        }
      }
    '
}

non_helper_tab_index() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      $1 == "-" && $2 ~ /^[0-9]+:$/ {
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url != needle && index(url, needle "?") != 1) {
          sub(/:$/, "", $2)
          print $2
          exit
        }
      }
    '
}

has_current_non_helper_tab() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      $1 == "-" && $2 ~ /^[0-9]+:$/ && index($0, "(current)") {
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url != needle && index(url, needle "?") != 1)
          found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '
}

has_non_helper_tab() {
  local tabs="$1"

  printf '%s\n' "$tabs" |
    awk -v needle="$extension_connect_url" '
      $1 == "-" && $2 ~ /^[0-9]+:$/ {
        field_count = split($0, fields, /\]\(/)
        if (field_count < 2)
          next
        url = fields[field_count]
        sub(/\)$/, "", url)
        if (url != needle && index(url, needle "?") != 1)
          found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '
}

known_output_dir() {
  local base=""
  local directory=""

  if [[ ! -e "$output_path_file" && ! -L "$output_path_file" ]]; then
    return 1
  fi
  private_state_file_is_valid "$output_path_file" || return 2
  exec 3<"$output_path_file"
  IFS= read -r directory <&3 || {
    exec 3<&-
    return 2
  }
  if IFS= read -r <&3; then
    exec 3<&-
    return 2
  fi
  exec 3<&-
  base="${directory#"$runtime_dir"/}"
  [[ "$directory" == "$runtime_dir/$base" ]] || return 2
  [[ "$base" != */* ]] || return 2
  [[ "$base" =~ ^session-output\.[A-Za-z0-9]{6}$ ]] || return 2
  printf '%s\n' "$directory"
}

output_directory_is_valid() {
  local base=""
  local directory="$1"

  base="${directory#"$runtime_dir"/}"
  [[ "$directory" == "$runtime_dir/$base" ]] || return 1
  [[ "$base" != */* ]] || return 1
  [[ "$base" =~ ^session-output\.[A-Za-z0-9]{6}$ ]] || return 1
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$directory")" == "700" ]]
}

scrub_directory() {
  local directory="$1"
  local remaining=""

  [[ -n "$directory" ]] || return 1
  if [[ ! -e "$directory" && ! -L "$directory" ]]; then
    return 0
  fi
  output_directory_is_valid "$directory" || return 1
  if ! /usr/bin/find "$directory" -depth -mindepth 1 -delete 2>/dev/null; then
    return 1
  fi
  remaining="$(/usr/bin/find "$directory" -mindepth 1 -print -quit 2>/dev/null)" ||
    return 1
  [[ -z "$remaining" ]]
}

scrub_known_output() {
  local directory=""
  local status=0

  directory="$(known_output_dir)" || status=$?
  if (( status == 1 )); then
    return 0
  elif (( status != 0 )); then
    echo "Private Playwright output metadata is invalid; refusing cleanup." >&2
    return 1
  fi
  scrub_directory "$directory"
}

remove_known_output() {
  local directory=""
  local status=0

  directory="$(known_output_dir)" || status=$?
  if (( status == 1 )); then
    remove_private_state_file "$sanitize_marker" || return 1
    return 0
  elif (( status != 0 )); then
    echo "Private Playwright output metadata is invalid; refusing cleanup." >&2
    return 1
  fi
  scrub_directory "$directory" || return 1
  if [[ -d "$directory" ]] && ! rmdir "$directory" 2>/dev/null; then
    return 1
  fi
  remove_private_state_file "$output_path_file" || return 1
  remove_private_state_file "$sanitize_marker" || return 1
}

sanitize_bootstrap_tab() {
  local initial_tabs="$1"
  local guarded_output_file="${2:-}"
  local attempt=0
  local helper_line=""
  local non_helper_index=""
  local tabs="$initial_tabs"

  helper_line="$(helper_tab_line "$tabs")"
  if [[ -z "$helper_line" ]]; then
    echo "Playwright's required extension helper tab is unavailable." >&2
    echo "The owned session cannot be considered persistent." >&2
    return 1
  fi

  # connect.html owns the extension heartbeat and cannot be evaluated,
  # navigated, or closed through this relay. Keep it untouched in the
  # background and ensure a normal controlled tab has focus.
  if has_current_non_helper_tab "$tabs"; then
    return 0
  fi

  if has_non_helper_tab "$tabs"; then
    non_helper_index="$(non_helper_tab_index "$tabs")"
    if [[ -z "$non_helper_index" ]] ||
      ! run_cli_bounded 80 --raw -s="$session_name" \
        tab-select "$non_helper_index" >/dev/null 2>&1; then
      echo "Playwright attached, but could not foreground a controlled tab." >&2
      return 1
    fi
  else
    if ! run_cli_bounded 80 --raw -s="$session_name" tab-new \
      >/dev/null 2>&1; then
      echo "Playwright attached, but could not create a safe foreground tab." >&2
      return 1
    fi
  fi

  attempt=0
  while (( attempt < 30 )); do
    if [[ -n "$guarded_output_file" ]]; then
      list_tabs_guarded "$guarded_output_file" || return 1
      tabs="$listed_tabs"
    else
      tabs="$(list_tabs)" || return 1
    fi
    if [[ -n "$(helper_tab_line "$tabs")" ]] &&
      has_current_non_helper_tab "$tabs"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done

  echo "Playwright attached, but its foreground tab did not become current." >&2
  return 1
}

finalize_sanitation() {
  local guarded_output_file="${2:-}"
  local marker_exists=0
  local sanitize_status=0
  local scrub_status=0
  local tabs="$1"

  if [[ -e "$sanitize_marker" || -L "$sanitize_marker" ]]; then
    private_state_file_is_valid "$sanitize_marker" || {
      echo "The Playwright sanitation marker is invalid." >&2
      return 1
    }
    marker_exists=1
  fi

  if [[ -n "$(helper_tab_line "$tabs")" && "$marker_exists" == "0" ]]; then
    if ! write_private_state_file "$sanitize_marker" "pending"; then
      echo "Could not mark the Playwright helper tab for sanitation." >&2
      return 1
    fi
    marker_exists=1
  fi

  sanitize_bootstrap_tab "$tabs" "$guarded_output_file" ||
    sanitize_status=$?

  if (( marker_exists == 1 )); then
    if ! scrub_known_output; then
      echo "Could not securely scrub Playwright bootstrap artifacts." >&2
      scrub_status=1
    fi
    if (( sanitize_status == 0 && scrub_status == 0 )); then
      if ! remove_private_state_file "$sanitize_marker"; then
        echo "Could not clear the Playwright sanitation marker." >&2
        scrub_status=1
      fi
    fi
  fi

  if (( sanitize_status != 0 )); then
    return "$sanitize_status"
  fi
  return "$scrub_status"
}

lock_directory_is_valid() {
  private_dir_is_valid "$lock_dir"
}

lock_pid_file_is_valid() {
  local pid_file="$lock_dir/pid"

  [[ -f "$pid_file" && ! -L "$pid_file" && -O "$pid_file" ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$pid_file")" == "600" ]]
}

remove_lock_safely() {
  local pid_file="$lock_dir/pid"

  lock_directory_is_valid || return 1
  if [[ -e "$pid_file" || -L "$pid_file" ]]; then
    lock_pid_file_is_valid || return 1
    /bin/rm -f "$pid_file" || return 1
  fi
  /bin/rmdir "$lock_dir" 2>/dev/null
}

release_lock() {
  if (( lock_held == 1 )); then
    if ! remove_lock_safely; then
      echo "WARNING: Could not safely remove the lock." >&2
    fi
    lock_held=0
  fi
}

acquire_lock() {
  local attempts=0
  local owner=""
  local ownerless_attempts=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    if ! lock_directory_is_valid; then
      echo "The lock path is not a private owned directory." >&2
      echo "Refusing to read or remove it." >&2
      return 1
    fi
    owner=""
    if [[ -e "$lock_dir/pid" || -L "$lock_dir/pid" ]]; then
      if ! lock_pid_file_is_valid; then
        echo "The lock PID file is not a private owned regular file." >&2
        echo "Refusing to read or remove it." >&2
        return 1
      fi
      read -r owner <"$lock_dir/pid" || owner=""
    fi

    if [[ -n "$owner" && "$owner" =~ ^[0-9]+$ ]]; then
      ownerless_attempts=0
      if ! kill -0 "$owner" 2>/dev/null; then
        if ! remove_lock_safely; then
          echo "Could not safely remove a stale lock." >&2
          return 1
        fi
        continue
      fi
    else
      ownerless_attempts=$((ownerless_attempts + 1))
      if (( ownerless_attempts >= 20 )); then
        if ! remove_lock_safely; then
          echo "Could not safely remove an ownerless lock." >&2
          return 1
        fi
        ownerless_attempts=0
        continue
      fi
    fi

    if (( attempts >= 200 )); then
      echo "Timed out waiting for another connection attempt." >&2
      return 1
    fi

    attempts=$((attempts + 1))
    sleep 0.1
  done

  if ! lock_directory_is_valid; then
    echo "The newly created lock is invalid." >&2
    return 1
  fi
  if ! printf '%s\n' "$$" >"$lock_dir/pid"; then
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  if ! lock_pid_file_is_valid; then
    /bin/rm -f "$lock_dir/pid"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  lock_held=1
}

cleanup_on_exit() {
  local attachment_recovery=0

  if (( attachment_requires_recovery == 1 )); then
    attachment_recovery=1
    attachment_requires_recovery=0
    unset PLAYWRIGHT_MCP_EXTENSION_TOKEN
    unset token 2>/dev/null || true
  fi
  terminate_active_bounded_child
  remove_setup_staging
  if (( attachment_recovery == 1 )); then
    echo "SECURITY: Attachment was interrupted; running targeted recovery." >&2
    detach_failed_attachment || true
    if ! remove_known_output; then
      echo "WARNING: Interrupted attachment artifacts still require cleanup." >&2
    fi
  fi
  release_lock
  if [[ -e "$sanitize_marker" || -L "$sanitize_marker" ]]; then
    if ! private_state_file_is_valid "$sanitize_marker" ||
      ! scrub_known_output; then
      echo "WARNING: Playwright bootstrap artifacts still require cleanup." >&2
    fi
  fi
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -e "$sanitize_marker" || -L "$sanitize_marker" ]]; then
  if ! private_state_file_is_valid "$sanitize_marker" ||
    ! scrub_known_output; then
    die "Could not securely scrub pending Playwright bootstrap artifacts."
  fi
fi

assert_no_attached_chrome_conflict() {
  local conflicts=""

  if ! conflicts="$(conflicting_attached_chrome_sessions)"; then
    echo "Could not inspect other Playwright workspaces safely." >&2
    echo "No attachment was attempted." >&2
    return 1
  fi
  if [[ -n "$conflicts" ]]; then
    echo "Another workspace already owns a potentially conflicting attached Chrome session:" >&2
    printf '  %s\n' "$conflicts" >&2
    echo "Disconnect that session before attaching this shared wrapper." >&2
    return 1
  fi
}

detach_failed_attachment() {
  local status=0

  run_cli_bounded 80 -s="$session_name" detach >/dev/null 2>&1 || status=$?
  if (( status == 0 )); then
    echo "The named Playwright session was detached." >&2
    return 0
  fi

  echo "SECURITY: Automatic session detachment failed (status $status)." >&2
  echo "Treat the session as connected; fully quit Chrome and rotate the token." >&2
  return "$status"
}

attach_session() {
  local attach_config=""
  local attach_log=""
  local attach_output_dir=""
  local attach_status=0
  local chrome_pids_after=""
  local chrome_pids_before=""
  local chrome_pids_current=""
  local cleanup_status=0
  local detach_status=0
  local process_token_state=""
  local tabs=""
  local tabs_output=""
  local token=""

  chrome_pids_before="$(require_running_normal_chrome)" || return $?
  assert_no_attached_chrome_conflict || return 1
  token="$(read_token)" || return 3
  if ! attach_output_dir="$(mktemp -d "$runtime_dir/session-output.XXXXXX")"; then
    unset token
    echo "Could not create a private Playwright bootstrap directory." >&2
    return 1
  fi
  attach_config="$attach_output_dir/cli.config.json"
  attach_log="$attach_output_dir/attach.log"
  tabs_output="$attach_output_dir/tabs.log"

  if ! write_private_state_file "$output_path_file" "$attach_output_dir"; then
    rmdir "$attach_output_dir" 2>/dev/null || true
    unset token
    return 1
  fi
  if ! write_private_state_file "$sanitize_marker" "pending"; then
    remove_known_output || true
    unset token
    echo "Could not mark the Playwright bootstrap for sanitation." >&2
    return 1
  fi

  if ! "$node_bin" -e '
    const fs = require("fs");
    fs.writeFileSync(
      process.argv[1],
      JSON.stringify({ outputDir: process.argv[2] })
    );
  ' "$attach_config" "$attach_output_dir"; then
    if ! remove_known_output; then
      echo "Could not securely remove the failed bootstrap directory." >&2
    fi
    unset token
    echo "Could not create the private Playwright bootstrap configuration." >&2
    return 1
  fi

  chrome_pids_current="$(normal_chrome_pids)"
  if [[ -z "$chrome_pids_current" ||
    "$chrome_pids_current" != "$chrome_pids_before" ]]; then
    unset token
    if ! remove_known_output; then
      echo "Could not securely remove the aborted bootstrap artifacts." >&2
    fi
    echo "Normal Chrome changed before Playwright could attach." >&2
    echo "No extension connection was attempted. Reopen Chrome manually and retry." >&2
    return 5
  fi

  attachment_requires_recovery=1
  PLAYWRIGHT_MCP_EXTENSION_TOKEN="$token" \
    run_cli_bounded_to_file "$attach_log" "$attach_timeout_attempts" --json attach \
      --session="$session_name" \
      --extension=chrome \
      --config="$attach_config" || attach_status=$?
  unset token

  if (( attach_status != 0 )); then
    detach_failed_attachment || detach_status=$?
    if ! remove_known_output; then
      cleanup_status=1
      echo "Could not securely remove the failed bootstrap artifacts." >&2
      return 1
    fi
    if (( detach_status == 0 && cleanup_status == 0 )); then
      attachment_requires_recovery=0
    fi
    if (( attach_status == 124 )); then
      echo "Playwright attachment timed out after 60 seconds." >&2
      echo "Termination was issued to the exact CLI child and its direct descendants." >&2
      echo "Private bootstrap artifacts were removed." >&2
      echo "Complete the token-rotation procedure before reconnecting." >&2
    else
      echo "Playwright could not attach to your existing Chrome profile." >&2
      echo "Bootstrap details were suppressed because they may contain the extension token." >&2
      if (( detach_status != 0 )); then
        echo "Complete the token-rotation procedure before reconnecting." >&2
      fi
    fi
    return "$attach_status"
  fi

  chrome_pids_after="$(normal_chrome_pids)"
  process_token_state="$(persistent_extension_token_state)"
  if [[ -z "$chrome_pids_after" ||
    "$chrome_pids_after" != "$chrome_pids_before" ||
    "$process_token_state" != "absent" ]]; then
    detach_failed_attachment || detach_status=$?
    if ! remove_known_output; then
      cleanup_status=1
      echo "Could not securely remove Playwright's aborted bootstrap output." >&2
    fi
    if (( detach_status == 0 && cleanup_status == 0 )); then
      attachment_requires_recovery=0
    fi
    echo "SECURITY: Chrome changed or retained the extension token during attachment." >&2
    if (( detach_status == 0 )); then
      echo "No page command was attempted after detachment." >&2
    else
      echo "No page command was attempted, but the session may remain connected." >&2
    fi
    echo "Fully quit Chrome and complete the token-rotation procedure before reconnecting." >&2
    return 6
  fi

  if ! scrub_known_output; then
    echo "Could not securely scrub Playwright's initial bootstrap output." >&2
    return 1
  fi

  if ! list_tabs_guarded "$tabs_output"; then
    echo "Playwright attached, but the Chrome session did not become ready." >&2
    return 1
  fi
  tabs="$listed_tabs"

  finalize_sanitation "$tabs" "$tabs_output" || attach_status=$?
  if (( attach_status == 0 )); then
    attachment_requires_recovery=0
  fi
  return "$attach_status"
}

ensure_session() {
  local allow_attach="${2:-false}"
  local attach_status=0
  local quiet="${1:-false}"
  local result="reused"
  local state=""
  local tabs=""

  acquire_lock || return 1
  # A concurrent setup can replace the CLI before this function holds the
  # lock, so this check repeats before any attaching CLI call.
  if ! require_usable_cli "$(supported_cli_fault)"; then
    release_lock
    return 2
  fi
  state="$(session_state)"

  case "$state" in
    ready)
      if ! tabs="$(list_tabs)"; then
        echo "The Chrome session could not be probed after three attempts." >&2
        echo "No reconnect was attempted; run 'doctor' and retry." >&2
        release_lock
        return 1
      fi
      attach_status=0
      finalize_sanitation "$tabs" || attach_status=$?
      if (( attach_status != 0 )); then
        release_lock
        return "$attach_status"
      fi
      ;;
    missing)
      if [[ "$allow_attach" != "true" ]]; then
        echo "No Playwright My Chrome session is currently owned by this skill." >&2
        echo "No attachment was attempted, so another extension client remains untouched." >&2
        echo "After explicit approval to take the exclusive Playwright Extension connection, run:" >&2
        echo "  $skill_dir/scripts/playwright-my-chrome.sh connect" >&2
        release_lock
        return 4
      fi
      attach_status=0
      attach_session || attach_status=$?
      if (( attach_status != 0 )); then
        release_lock
        return "$attach_status"
      fi
      result="attached"
      ;;
    stale)
      if [[ "$allow_attach" != "true" ]]; then
        echo "The owned Playwright My Chrome session is stale." >&2
        echo "No replacement was attempted, so another extension client remains untouched." >&2
        echo "After explicit approval to take the exclusive Playwright Extension connection, run:" >&2
        echo "  $skill_dir/scripts/playwright-my-chrome.sh connect" >&2
        release_lock
        return 4
      fi
      attach_status=0
      attach_session || attach_status=$?
      if (( attach_status != 0 )); then
        release_lock
        return "$attach_status"
      fi
      result="replaced stale"
      ;;
    unavailable)
      echo "Playwright session state remained unavailable after three attempts." >&2
      echo "No reconnect was attempted; run 'doctor' and retry." >&2
      release_lock
      return 1
      ;;
    *)
      echo "Unexpected Playwright session state: $state" >&2
      release_lock
      return 1
      ;;
  esac

  release_lock
  if [[ "$quiet" != "true" ]]; then
    echo "Playwright My Chrome is ready ($result session '$session_name')."
  fi
}

disconnect_session() {
  local after_pids=""
  local before_pids=""
  local display_pids=""
  local status=0

  before_pids="$(normal_chrome_pids)"
  run_cli_bounded 80 -s="$session_name" detach || status=$?
  if (( status == 0 )); then
    if ! remove_known_output; then
      echo "Detached, but could not remove the private session output." >&2
      return 1
    fi
    after_pids="$(normal_chrome_pids)"
    display_pids="$(printf '%s\n' "$after_pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ -n "$before_pids" && "$before_pids" == "$after_pids" ]]; then
      echo "Detached Playwright session '$session_name'; normal Chrome remains running (pid $display_pids)."
    elif [[ -n "$after_pids" ]]; then
      echo "Detached Playwright session '$session_name'; normal Chrome remains running (pid $display_pids)."
    else
      echo "Detached Playwright session '$session_name'; normal Chrome is no longer running." >&2
      return 1
    fi
  fi
  return "$status"
}

doctor() {
  local chrome_count=0
  local chrome_pid=""
  local chrome_pids=""
  local compatibility=""
  local fault=""
  local process_token_state=""
  local rotation=""
  local state=""
  local token_state="missing"
  local version=""

  version="not installed"
  if [[ -f "$private_cli_entry" ]]; then
    version="$(cli_entry_version "$private_cli_entry" || true)"
    [[ -n "$version" ]] || version="unknown"
  fi
  fault="$(supported_cli_fault)"
  if [[ -z "$fault" ]]; then
    compatibility="supported (requires $supported_cli_version)"
    state="$(session_state)"
  else
    compatibility="unsupported (requires $supported_cli_version; private CLI $fault; run setup)"
    state="not checked (unsupported CLI)"
  fi
  token_is_stored && token_state="stored"
  chrome_pids="$(normal_chrome_pids)"
  chrome_count="$(printf '%s\n' "$chrome_pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( chrome_count == 1 )); then
    chrome_pid="$chrome_pids"
  fi
  process_token_state="$(persistent_extension_token_state)"
  rotation="$(rotation_metadata_state)"

  echo "Playwright My Chrome"
  echo "cli:       $private_cli_dir"
  echo "version:   $version"
  echo "compatibility: $compatibility"
  echo "token:     $token_state"
  echo "session:   $state"
  if (( chrome_count == 1 )); then
    echo "chrome:    running (normal user Chrome, pid $chrome_pid)"
  elif (( chrome_count > 1 )); then
    echo "chrome:    ambiguous (multiple normal Chrome main processes)"
  else
    echo "chrome:    missing (connect will refuse to launch it)"
  fi
  echo "process-token: $process_token_state"
  echo "rotation:  $rotation"
  echo "workspace: $runtime_dir"
}

cleanup_plan() {
  local payload=""

  if ! payload="$(run_cli_bounded 80 --json list --all 2>/dev/null)"; then
    echo "Could not inspect Playwright sessions safely." >&2
    return 1
  fi

  printf '%s' "$payload" |
    "$node_bin" -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", chunk => input += chunk);
      process.stdin.on("end", () => {
        let payload;
        try {
          payload = JSON.parse(input);
        } catch {
          process.stderr.write("Could not parse Playwright session inventory.\n");
          process.exitCode = 1;
          return;
        }

        const browsers = (payload.browsers || []).filter(browser =>
          browser.status === "open"
        );
        process.stdout.write("Targeted Playwright cleanup plan\n");
        if (!browsers.length)
          process.stdout.write("active sessions: none\n");
        for (const browser of browsers) {
          const action = browser.attached === true ? "detach" : "close";
          process.stdout.write(
            "session: " + browser.name + "\n" +
            "workspace: " + browser.workspace + "\n" +
            "safe action: " + action + " it through the tool that owns it\n"
          );
        }
        process.stdout.write("global close-all: blocked by this skill\n");
        process.stdout.write("global kill-all: blocked by this skill\n");
        process.stdout.write("non-CLI Chrome: close through its owning test or automation tool\n");
      });
    '
}

safety_audit() {
  local chrome_count=0
  local chrome_pid=""
  local chrome_pids=""
  local process_token_state=""

  chrome_pids="$(normal_chrome_pids)"
  chrome_count="$(printf '%s\n' "$chrome_pids" | awk 'NF { count++ } END { print count + 0 }')"
  if (( chrome_count == 1 )); then
    chrome_pid="$chrome_pids"
  fi
  process_token_state="$(persistent_extension_token_state)"

  echo "Playwright My Chrome safeguards"
  if (( chrome_count == 1 )); then
    echo "1. running-Chrome preflight: PASS (normal Chrome pid $chrome_pid)"
  elif (( chrome_count > 1 )); then
    echo "1. running-Chrome preflight: BLOCKED (multiple normal Chrome main processes)"
  else
    echo "1. running-Chrome preflight: BLOCKED (normal Chrome missing)"
  fi
  echo "2. missing-Chrome behavior: ENFORCED (connect exits before token read or attach)"
  echo "3. browser launch commands: BLOCKED (open/show/install/attach are unavailable)"
  echo "4. disconnect behavior: DETACH ONLY (external Chrome is never closed)"
  echo "5. cleanup policy: TARGETED ONLY (close-all and kill-all are blocked)"
  if [[ "$process_token_state" == "absent" ]]; then
    echo "6. persistent process token: PASS (absent)"
  else
    echo "6. persistent process token: ACTION REQUIRED (restart Chrome and rotate token)"
  fi
  echo "7. attach process continuity: ENFORCED (complete Chrome PID set must remain unchanged)"
}

print_help() {
  /bin/cat <<USAGE
Usage: playwright-my-chrome.sh <command> [arguments]

Wrapper commands:
  setup                   install the skill's private Playwright CLI
  doctor, status          report readiness without reading the token
  connect                 attach to the running Chrome (needs user approval)
  ensure                  check the owned session without attaching
  disconnect              detach the session; Chrome keeps running
  cleanup-plan            list Playwright sessions and their safe cleanup
  safety-audit            list the enforced safeguards
  begin-token-rotation, mark-token-regenerated, rotation-status
                          rotate an exposed extension token

Blocked: open, attach, show, install, install-browser, delete-data,
close-all, kill-all.

Other commands go to the private Playwright CLI in session '$session_name'.
USAGE
  if [[ -n "$(supported_cli_fault)" ]]; then
    echo "Playwright CLI commands are listed here after: $setup_command"
    return 0
  fi
  echo
  run_cli "${forward_args[@]:---help}"
}

record_explicit_session() {
  local value="$1"

  [[ -n "$value" ]] || die "A session option was provided without a value."
  if [[ -n "$explicit_session" && "$explicit_session" != "$value" ]]; then
    die "Conflicting session options were provided."
  fi
  explicit_session="$value"
}

wrapper_command_has_extras() {
  local argument=""
  local command_seen=0

  for argument in "${forward_args[@]}"; do
    if (( command_seen == 0 )) && [[ "$argument" == "$command_name" ]]; then
      command_seen=1
      continue
    fi
    case "$argument" in
      --json|--raw)
        ;;
      *)
        return 0
        ;;
    esac
  done
  return 1
}

original_args=("$@")
forward_args=()
command_name=""
explicit_session=""
help_requested=0
options_ended=0
version_requested=0

argument_index=0
while (( argument_index < ${#original_args[@]} )); do
  argument="${original_args[$argument_index]}"
  if (( options_ended == 1 )); then
    forward_args+=("$argument")
    if [[ -z "$command_name" ]]; then
      command_name="$argument"
    fi
    argument_index=$((argument_index + 1))
    continue
  fi
  case "$argument" in
    --)
      options_ended=1
      forward_args+=("$argument")
      ;;
    -s|--session)
      argument_index=$((argument_index + 1))
      (( argument_index < ${#original_args[@]} )) ||
        die "A session option was provided without a value."
      record_explicit_session "${original_args[$argument_index]}"
      ;;
    -s=*|--session=*)
      record_explicit_session "${argument#*=}"
      ;;
    --help|-h)
      help_requested=1
      forward_args+=("$argument")
      ;;
    --version|-v)
      version_requested=1
      forward_args+=("$argument")
      ;;
    *)
      forward_args+=("$argument")
      if [[ -z "$command_name" && "$argument" != -* ]]; then
        command_name="$argument"
      fi
      ;;
  esac
  argument_index=$((argument_index + 1))
done

if [[ -n "$explicit_session" && "$explicit_session" != "$session_name" ]]; then
  die "This wrapper only controls session '$session_name', not '$explicit_session'."
fi

if (( version_requested == 1 )); then
  require_usable_cli "$(supported_cli_fault)"
  run_cli "${forward_args[@]}"
  exit $?
fi
if (( help_requested == 1 )) || [[ -z "$command_name" ]]; then
  print_help
  exit $?
fi

case "$command_name" in
  setup)
    wrapper_command_has_extras &&
      die "'setup' does not accept browser-command arguments."
    setup_private_cli
    ;;
  doctor|status)
    wrapper_command_has_extras &&
      die "'$command_name' does not accept browser-command arguments."
    doctor
    ;;
  begin-token-rotation)
    wrapper_command_has_extras &&
      die "'begin-token-rotation' does not accept browser-command arguments."
    begin_token_rotation
    ;;
  mark-token-regenerated)
    wrapper_command_has_extras &&
      die "'mark-token-regenerated' does not accept browser-command arguments."
    mark_token_regenerated
    ;;
  rotation-status)
    wrapper_command_has_extras &&
      die "'rotation-status' does not accept browser-command arguments."
    token_rotation_status
    ;;
  safety-audit)
    wrapper_command_has_extras &&
      die "'safety-audit' does not accept browser-command arguments."
    safety_audit
    ;;
  cleanup-plan)
    wrapper_command_has_extras &&
      die "'cleanup-plan' does not accept browser-command arguments."
    require_usable_cli "$(supported_cli_fault)"
    cleanup_plan
    ;;
  ensure)
    wrapper_command_has_extras &&
      die "'ensure' does not accept browser-command arguments."
    ensure_session false false
    ;;
  connect)
    wrapper_command_has_extras &&
      die "'connect' does not accept browser-command arguments."
    ensure_session false true
    ;;
  attach)
    die "'attach' is disabled. Use 'connect' only after explicit approval to take the exclusive extension connection."
    ;;
  disconnect|detach|close)
    wrapper_command_has_extras &&
      die "'$command_name' does not accept browser-command arguments."
    # An intact copy from another skill release can still end the session, so
    # setup can replace that copy afterwards.
    require_usable_cli "$(intact_cli_fault "$private_cli_dir")"
    disconnect_session
    ;;
  open)
    die "'open' would replace your existing Chrome. Use 'goto <url>' instead."
    ;;
  close-all|kill-all|delete-data|install|install-browser|show)
    die "'$command_name' is outside this wrapper's safe scope."
    ;;
  list)
    require_usable_cli "$(supported_cli_fault)"
    run_cli "${forward_args[@]}"
    ;;
  *)
    ensure_session true false
    run_cli_redacted -s="$session_name" "${forward_args[@]}"
    ;;
esac
