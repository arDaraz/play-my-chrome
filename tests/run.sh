#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$repo_root/skills/playwright-my-chrome/scripts/playwright-my-chrome.sh"
store_token="$repo_root/skills/playwright-my-chrome/scripts/store-extension-token.sh"
mock_dir="$repo_root/tests/mocks"
cli_lock="$repo_root/skills/playwright-my-chrome/cli/package-lock.json"
locked_cli_version="$(
  node -p 'require(process.argv[1]).packages["node_modules/@playwright/cli"].version' \
    "$cli_lock"
)"
case_dir=""
output=""
status=0
passed=0

cleanup_case() {
  if [[ -n "$case_dir" && -d "$case_dir" ]]; then
    /usr/bin/find "$case_dir" -depth -delete
  fi
  case_dir=""
}

trap cleanup_case EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  [[ "$status" == "$expected" ]] ||
    fail "expected status $expected, got $status; output: $output"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] ||
    fail "expected output to contain '$needle'; output: $haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] ||
    fail "output unexpectedly contained '$needle'"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  /usr/bin/grep -Fq -- "$needle" "$file" ||
    fail "expected $file to contain '$needle'"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if /usr/bin/grep -Fq -- "$needle" "$file"; then
    fail "$file unexpectedly contained '$needle'"
  fi
}

run_capture() {
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
}

setup_case() {
  local temp_root="${TMPDIR:-/tmp}"

  cleanup_case
  case_dir="$(/usr/bin/mktemp -d "${temp_root%/}/playwright-my-chrome-test.XXXXXX")"
  /bin/chmod 700 "$case_dir"
  /bin/mkdir "$case_dir/home"
  /bin/chmod 700 "$case_dir/home"

  export HOME="$case_dir/home"
  export PLAYWRIGHT_MY_CHROME_TEST_MODE=1
  export PLAYWRIGHT_MY_CHROME_NODE
  PLAYWRIGHT_MY_CHROME_NODE="$(command -v node)"
  export PLAYWRIGHT_MY_CHROME_RUNTIME_DIR="$case_dir/runtime"
  export PLAYWRIGHT_MY_CHROME_EXECUTABLE="/Applications/Test Chrome.app/Contents/MacOS/Test Chrome"
  export PLAYWRIGHT_MY_CHROME_TEST_SECURITY_BIN="$mock_dir/mock-security.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_PS_BIN="$mock_dir/mock-ps.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_PBPASTE_BIN="$mock_dir/mock-pbpaste.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_PBCOPY_BIN="$mock_dir/mock-pbcopy.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_NPM_BIN="$mock_dir/mock-npm.sh"
  export PLAYWRIGHT_MY_CHROME_TEST_MV_BIN="$mock_dir/mock-mv.sh"
  export MOCK_MV_PID_FILE="$case_dir/mv.pid"
  export MOCK_CLI_LOG="$case_dir/cli.log"
  export MOCK_NPM_LOG="$case_dir/npm.log"
  export MOCK_SECURITY_LOG="$case_dir/security.log"
  export MOCK_SESSION_STATE_FILE="$case_dir/session.state"
  export MOCK_PS_OUTPUT_FILE="$case_dir/ps.out"
  export MOCK_KEYCHAIN_TOKEN_FILE="$case_dir/keychain-token"
  export MOCK_CLIPBOARD_FILE="$case_dir/clipboard"
  export MOCK_ATTACH_PID_FILE="$case_dir/attach.pid"
  export MOCK_TAB_LIST_PID_FILE="$case_dir/tab-list.pid"
  export MOCK_NPM_MODE="stable"
  export MOCK_NPM_PID_FILE="$case_dir/npm.pid"
  export MOCK_ATTACH_MODE="stable"
  export MOCK_DETACH_MODE="stable"
  export MOCK_TAB_LIST_MODE="stable"
  export MOCK_CHANGE_PID_ON_LIST_ALL="0"
  unset MOCK_CLI_VERSION MOCK_SESSION_COMPATIBLE MOCK_MV_HANG_TARGET \
    MOCK_MV_FAIL_RESTORE MOCK_PS_MODE \
    PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS \
    PLAYWRIGHT_MY_CHROME_TEST_SETUP_TIMEOUT_ATTEMPTS

  : >"$MOCK_CLI_LOG"
  : >"$MOCK_SECURITY_LOG"
  : >"$MOCK_SESSION_STATE_FILE"
  : >"$MOCK_PS_OUTPUT_FILE"
  : >"$MOCK_CLIPBOARD_FILE"
  printf '%s\n' "TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" \
    >"$MOCK_KEYCHAIN_TOKEN_FILE"

  run_capture "$wrapper" setup
  assert_status 0
  : >"$MOCK_CLI_LOG"
  : >"$MOCK_NPM_LOG"
}

file_digest() {
  /usr/bin/shasum -a 256 <"$1" | /usr/bin/awk '{ print $1 }'
}

remove_private_cli() {
  /usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli" -depth -delete
}

copy_skill_with_locked_version() {
  local version="$1"
  local destination="${2:-$case_dir/skill}"

  /bin/cp -R "$repo_root/skills/playwright-my-chrome" "$destination"
  node -e '
    const fs = require("fs");
    const [manifestPath, lockPath, version] = process.argv.slice(1);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
    manifest.dependencies["@playwright/cli"] = version;
    lock.packages[""].dependencies["@playwright/cli"] = version;
    lock.packages["node_modules/@playwright/cli"].version = version;
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
    fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + "\n");
  ' "$destination/cli/package.json" "$destination/cli/package-lock.json" "$version"
}

assert_process_gone() {
  local pid="$1"

  if kill -0 "$pid" 2>/dev/null; then
    fail "process $pid is still running"
  fi
}

wait_for_file() {
  local file="$1"
  local owner_pid="$2"
  local wait_attempt=0

  while [[ ! -s "$file" ]]; do
    kill -0 "$owner_pid" 2>/dev/null ||
      fail "process $owner_pid exited before writing $file"
    wait_attempt=$((wait_attempt + 1))
    (( wait_attempt < 100 )) || fail "timed out waiting for $file"
    sleep 0.05
  done
}

assert_no_setup_leftovers() {
  [[ -z "$(/usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" \
    -maxdepth 1 -name '.cli-setup.*' -print -quit)" ]] ||
    fail "setup left a staging directory in the runtime"
}

set_normal_chrome() {
  local pid="${1:-111}"
  printf '%s %s\n' "$pid" "$PLAYWRIGHT_MY_CHROME_EXECUTABLE" \
    >"$MOCK_PS_OUTPUT_FILE"
}

set_multiple_normal_chrome() {
  printf '111 %s\n222 %s\n' \
    "$PLAYWRIGHT_MY_CHROME_EXECUTABLE" \
    "$PLAYWRIGHT_MY_CHROME_EXECUTABLE" \
    >"$MOCK_PS_OUTPUT_FILE"
}

pass_test() {
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$1"
}

test_missing_chrome_refuses_before_token_read() {
  setup_case
  run_capture "$wrapper" connect
  assert_status 5
  assert_contains "$output" "No browser was launched"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "missing-Chrome path read the Keychain token"
  pass_test "missing Chrome refuses before token read or attachment"
}

test_ambiguous_chrome_refuses_before_token_read() {
  setup_case
  set_multiple_normal_chrome
  run_capture "$wrapper" connect
  assert_status 5
  assert_contains "$output" "Multiple normal Google Chrome main processes"
  assert_contains "$output" "browser ownership is ambiguous"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "ambiguous-Chrome path read the Keychain token"
  pass_test "multiple normal Chrome processes refuse before token read"
}

test_successful_connect_uses_stable_existing_chrome() {
  setup_case
  set_normal_chrome 111
  run_capture "$wrapper" connect
  assert_status 0
  assert_contains "$output" "ready (attached session 'mychrome')"
  assert_not_contains "$output" "TEST_ONLY_TOKEN"
  assert_file_contains "$MOCK_CLI_LOG" "--json attach"
  assert_file_contains "$MOCK_CLI_LOG" "attach-token-present"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "bootstrap sanitation marker remained after successful attachment"
  pass_test "stable existing Chrome attaches without exposing the token"
}

test_pid_change_during_attach_fails_closed() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="pid-change"
  run_capture "$wrapper" connect
  assert_status 6
  assert_contains "$output" "SECURITY: Chrome changed"
  assert_contains "$output" "token-rotation procedure"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  pass_test "Chrome PID change during attachment detaches and fails closed"
}

test_added_pid_during_attach_fails_closed() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="add-pid"
  run_capture "$wrapper" connect
  assert_status 6
  assert_contains "$output" "SECURITY: Chrome changed"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  pass_test "an added Chrome PID during attachment fails closed"
}

test_process_token_during_attach_fails_closed() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="process-token"
  run_capture "$wrapper" connect
  assert_status 6
  assert_contains "$output" "SECURITY: Chrome changed or retained"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  pass_test "persistent process token detaches and requires rotation"
}

test_pid_change_before_attach_never_invokes_attach() {
  setup_case
  set_normal_chrome 111
  export MOCK_CHANGE_PID_ON_LIST_ALL="1"
  run_capture "$wrapper" connect
  assert_status 5
  assert_contains "$output" "changed before Playwright could attach"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  pass_test "pre-attach PID change never invokes Playwright attachment"
}

test_failed_attach_suppresses_token_and_scrubs_artifacts() {
  local token=""

  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="fail"
  token="$(<"$MOCK_KEYCHAIN_TOKEN_FILE")"
  run_capture "$wrapper" connect
  assert_status 22
  assert_not_contains "$output" "$token"
  assert_contains "$output" "Bootstrap details were suppressed"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "failed attach left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "failed attach left output metadata"
  [[ -z "$(/usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" \
    -maxdepth 1 -name 'session-output.*' -print -quit)" ]] ||
    fail "failed attach left a bootstrap directory"
  pass_test "failed attachment hides token-bearing output and scrubs artifacts"
}

test_hung_attach_is_terminated_and_scrubbed() {
  local attach_pid=""

  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="hang"
  export PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS=2
  run_capture "$wrapper" connect
  assert_status 124
  assert_contains "$output" "attachment timed out"
  assert_contains "$output" "token-rotation procedure"
  [[ -s "$MOCK_ATTACH_PID_FILE" ]] ||
    fail "hung attach did not record its child PID"
  attach_pid="$(<"$MOCK_ATTACH_PID_FILE")"
  if kill -0 "$attach_pid" 2>/dev/null; then
    fail "timed-out attach child $attach_pid is still running"
  fi
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "timed-out attach left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "timed-out attach left output metadata"
  pass_test "hung attachment is terminated, detached, and scrubbed"
}

test_hung_attach_reports_detach_failure() {
  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="hang"
  export MOCK_DETACH_MODE="fail"
  export PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS=2
  run_capture "$wrapper" connect
  assert_status 124
  assert_contains "$output" "Automatic session detachment failed (status 23)"
  assert_contains "$output" "Treat the session as connected"
  assert_not_contains "$output" "session was detached"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "detach-failure path left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "detach-failure path left output metadata"
  pass_test "timeout reports failed detachment without claiming success"
}

test_interrupted_attach_terminates_child_and_recovers() {
  local attach_pid=""
  local output_file=""
  local wrapper_pid=""

  setup_case
  set_normal_chrome 111
  export MOCK_ATTACH_MODE="hang"
  export PLAYWRIGHT_MY_CHROME_TEST_ATTACH_TIMEOUT_ATTEMPTS=600
  output_file="$case_dir/wrapper.out"
  "$wrapper" connect >"$output_file" 2>&1 &
  wrapper_pid=$!

  wait_for_file "$MOCK_ATTACH_PID_FILE" "$wrapper_pid"

  attach_pid="$(<"$MOCK_ATTACH_PID_FILE")"
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 143
  assert_contains "$output" "Attachment was interrupted"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  assert_file_contains "$MOCK_CLI_LOG" "detach-token-absent"
  if kill -0 "$attach_pid" 2>/dev/null; then
    fail "interrupted attach child $attach_pid is still running"
  fi
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "interrupted attach left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "interrupted attach left output metadata"
  pass_test "interrupt terminates the token-bearing child and runs recovery"
}

test_interrupted_post_attach_validation_recovers() {
  local child_pid=""
  local output_file=""
  local wrapper_pid=""

  setup_case
  set_normal_chrome 111
  output_file="$case_dir/wrapper.out"
  export MOCK_TAB_LIST_MODE="hang"
  "$wrapper" connect >"$output_file" 2>&1 &
  wrapper_pid=$!

  wait_for_file "$MOCK_TAB_LIST_PID_FILE" "$wrapper_pid"

  child_pid="$(<"$MOCK_TAB_LIST_PID_FILE")"
  kill -TERM "$wrapper_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 143
  assert_contains "$output" "Attachment was interrupted"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  assert_file_contains "$MOCK_CLI_LOG" "detach-token-absent"
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "interrupted post-attach validation child $child_pid is still running"
  fi
  [[ "$(<"$MOCK_SESSION_STATE_FILE")" == "missing" ]] ||
    fail "post-attach interrupt left the named session attached"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize" ]] ||
    fail "post-attach interrupt left the sanitation marker"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" ]] ||
    fail "post-attach interrupt left output metadata"
  [[ -z "$(/usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" \
    -maxdepth 1 -name 'session-output.*' -print -quit)" ]] ||
    fail "post-attach interrupt left a bootstrap directory"
  pass_test "interrupt during post-attach validation detaches and scrubs"
}

test_unsupported_cli_version_blocks_browser_commands() {
  setup_case
  set_normal_chrome 111
  export MOCK_CLI_VERSION="9.9.9"
  run_capture "$wrapper" connect
  assert_status 2
  assert_contains "$output" "requires @playwright/cli $locked_cli_version"
  assert_contains "$output" "$(printf '%q setup' "$wrapper")"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "unsupported CLI path read the Keychain token"
  pass_test "unsupported Playwright CLI version fails before browser access"
}

test_unsupported_cli_version_blocks_disconnect() {
  setup_case
  set_normal_chrome 111
  export MOCK_CLI_VERSION="9.9.9"
  run_capture "$wrapper" disconnect
  assert_status 2
  assert_contains "$output" "requires @playwright/cli $locked_cli_version"
  assert_file_not_contains "$MOCK_CLI_LOG" "detach"
  pass_test "unsupported Playwright CLI cannot detach the browser"
}

test_unsafe_commands_are_blocked_locally() {
  local command_name=""

  setup_case
  for command_name in open attach close-all kill-all install install-browser show; do
    run_capture "$wrapper" "$command_name"
    [[ "$status" != "0" ]] || fail "$command_name unexpectedly succeeded"
  done
  [[ ! -s "$MOCK_CLI_LOG" ]] ||
    fail "blocked commands reached the Playwright CLI"
  pass_test "browser launch and global cleanup commands are blocked"
}

test_symlink_lock_cannot_delete_outside_pid() {
  local outside_lock=""

  setup_case
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  outside_lock="$case_dir/outside-lock"
  /bin/mkdir "$outside_lock"
  /bin/chmod 700 "$outside_lock"
  printf '%s\n' "999999" >"$outside_lock/pid"
  /bin/chmod 600 "$outside_lock/pid"
  /bin/ln -s "$outside_lock" \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock"
  run_capture "$wrapper" ensure
  assert_status 1
  assert_contains "$output" "lock path is not a private owned directory"
  [[ "$(<"$outside_lock/pid")" == "999999" ]] ||
    fail "symlinked lock deleted or modified the outside PID file"
  pass_test "symlinked lock path cannot delete an outside PID file"
}

test_disconnect_preserves_normal_chrome_pid() {
  setup_case
  set_normal_chrome 111
  printf '%s\n' "ready" >"$MOCK_SESSION_STATE_FILE"
  run_capture "$wrapper" disconnect
  assert_status 0
  assert_contains "$output" "normal Chrome remains running (pid 111)"
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  assert_file_contains "$MOCK_PS_OUTPUT_FILE" "111"
  pass_test "disconnect detaches without closing normal Chrome"
}

test_store_token_uses_keychain_and_clears_clipboard() {
  local token="TEST_ONLY_NEW_TOKEN_abcdefghijklmnopqrstuvwxyz123456"

  setup_case
  : >"$MOCK_KEYCHAIN_TOKEN_FILE"
  printf 'PLAYWRIGHT_MCP_EXTENSION_TOKEN=%s\n' "$token" >"$MOCK_CLIPBOARD_FILE"
  run_capture "$store_token"
  assert_status 0
  assert_contains "$output" "stored in macOS Keychain; clipboard cleared"
  assert_not_contains "$output" "$token"
  [[ "$(<"$MOCK_KEYCHAIN_TOKEN_FILE")" == "$token" ]] ||
    fail "mock Keychain did not receive the expected token"
  [[ ! -s "$MOCK_CLIPBOARD_FILE" ]] ||
    fail "clipboard was not cleared"
  pass_test "token setup stores without printing and clears the clipboard"
}

test_doctor_reports_version_compatibility() {
  setup_case
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  assert_contains "$output" "cli:       $PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  assert_contains "$output" "version:   $locked_cli_version"
  assert_contains "$output" "compatibility: supported (requires $locked_cli_version)"
  export MOCK_CLI_VERSION="9.9.9"
  : >"$MOCK_CLI_LOG"
  : >"$MOCK_SECURITY_LOG"
  run_capture "$wrapper" doctor
  assert_status 0
  assert_contains "$output" "version:   9.9.9"
  assert_contains "$output" "compatibility: unsupported (requires $locked_cli_version; private CLI reports version 9.9.9"
  assert_contains "$output" "session:   not checked (unsupported CLI)"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json list"
  assert_file_not_contains "$MOCK_SECURITY_LOG" "-w"
  remove_private_cli
  run_capture "$wrapper" doctor
  assert_status 0
  assert_contains "$output" "version:   not installed"
  assert_contains "$output" "compatibility: unsupported (requires $locked_cli_version; private CLI is not installed; run setup)"
  pass_test "doctor reports the private CLI path, version, and compatibility"
}

test_traversal_metadata_cannot_escape_runtime() {
  local victim=""

  setup_case
  victim="$case_dir/victim"
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  /bin/mkdir "$victim"
  printf '%s\n' "keep" >"$victim/keep.txt"
  printf '%s\n' \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output.fake/../../victim" \
    >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path"
  printf '%s\n' "pending" \
    >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  /bin/chmod 600 \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path" \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  run_capture "$wrapper" safety-audit
  assert_status 1
  assert_contains "$output" "invalid; refusing cleanup"
  [[ "$(<"$victim/keep.txt")" == "keep" ]] ||
    fail "traversal-shaped metadata modified the outside victim"
  pass_test "cleanup rejects traversal-shaped output metadata"
}

test_symlink_metadata_cannot_modify_target() {
  local victim=""

  setup_case
  victim="$case_dir/victim.txt"
  set_normal_chrome 111
  run_capture "$wrapper" doctor
  assert_status 0
  printf '%s\n' "keep" >"$victim"
  /bin/ln -s "$victim" \
    "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/session-output-path"
  printf '%s\n' "pending" \
    >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  /bin/chmod 600 "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/needs-sanitize"
  run_capture "$wrapper" safety-audit
  assert_status 1
  assert_contains "$output" "invalid; refusing cleanup"
  [[ "$(<"$victim")" == "keep" ]] ||
    fail "symlink metadata modified its target"
  pass_test "cleanup rejects symlink output metadata"
}

test_setup_installs_from_shipped_lock_without_scripts() {
  setup_case
  remove_private_cli
  /bin/mkdir "$case_dir/caller-bin"
  PATH="$case_dir/caller-bin:$PATH" run_capture "$wrapper" setup
  assert_status 0
  assert_contains "$output" "Installed @playwright/cli $locked_cli_version"
  assert_file_contains "$MOCK_NPM_LOG" "args=ci --ignore-scripts --omit=dev --no-audit --no-fund"
  assert_file_contains "$MOCK_NPM_LOG" "lock=$(file_digest "$cli_lock")"
  assert_file_contains "$MOCK_NPM_LOG" "cwd=$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/.cli-setup."
  assert_file_contains "$MOCK_NPM_LOG" "path=${PLAYWRIGHT_MY_CHROME_NODE%/*}:/usr/bin:/bin:/usr/sbin:/sbin"
  assert_file_not_contains "$MOCK_NPM_LOG" "$case_dir/caller-bin"
  [[ -f "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/@playwright/cli/playwright-cli.js" ]] ||
    fail "setup did not install the private CLI entry point"
  assert_no_setup_leftovers
  pass_test "setup installs the shipped lock with npm ci and no install scripts"
}

test_setup_is_idempotent() {
  setup_case
  run_capture "$wrapper" setup
  assert_status 0
  assert_contains "$output" "already installed"
  [[ ! -s "$MOCK_NPM_LOG" ]] ||
    fail "setup ran npm again although the private CLI already matched"
  pass_test "setup is a no-op when the private CLI already matches the lock"
}

test_failed_setup_leaves_no_partial_copy() {
  setup_case
  remove_private_cli
  export MOCK_NPM_MODE="fail"
  run_capture "$wrapper" setup
  assert_status 1
  assert_contains "$output" "npm ci failed"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli" ]] ||
    fail "failed npm ci left a private CLI directory"
  assert_no_setup_leftovers

  export MOCK_NPM_MODE="stable"
  export MOCK_CLI_VERSION="9.9.9"
  run_capture "$wrapper" setup
  assert_status 1
  assert_contains "$output" "reports version 9.9.9, not its locked $locked_cli_version"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli" ]] ||
    fail "a staged CLI with the wrong version was moved into place"
  assert_no_setup_leftovers
  pass_test "failed setup leaves no partial or wrong-version private CLI"
}

test_missing_private_cli_refuses_before_browser_access() {
  setup_case
  set_normal_chrome 111
  remove_private_cli
  run_capture "$wrapper" connect
  assert_status 2
  assert_contains "$output" "private Playwright CLI is not installed"
  assert_contains "$output" "$(printf '%q setup' "$wrapper")"
  [[ ! -s "$MOCK_CLI_LOG" ]] ||
    fail "missing private CLI path reached a Playwright CLI"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "missing private CLI path read the Keychain token"
  pass_test "missing private CLI exits 2 before token or browser access"
}

test_new_lock_version_requires_setup_and_replaces_copy() {
  local copied_wrapper=""

  setup_case
  set_normal_chrome 111
  copy_skill_with_locked_version "0.1.999"
  copied_wrapper="$case_dir/skill/scripts/playwright-my-chrome.sh"
  printf '%s\n' "old" >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/old-copy-marker"
  run_capture "$copied_wrapper" connect
  assert_status 2
  assert_contains "$output" "was installed from another skill release's lockfile"
  assert_contains "$output" "requires @playwright/cli 0.1.999"
  assert_contains "$output" "$(printf '%q setup' "$case_dir/skill/scripts/playwright-my-chrome.sh")"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "version mismatch path read the Keychain token"

  run_capture "$copied_wrapper" setup
  assert_status 0
  assert_file_contains "$MOCK_NPM_LOG" "lock=$(file_digest "$case_dir/skill/cli/package-lock.json")"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/old-copy-marker" ]] ||
    fail "setup kept files from the previous private CLI"
  assert_no_setup_leftovers
  run_capture "$copied_wrapper" doctor
  assert_status 0
  assert_contains "$output" "compatibility: supported (requires 0.1.999)"
  pass_test "a new locked version exits 2 until setup replaces the private CLI"
}

test_missing_lock_fails_closed() {
  setup_case
  /bin/cp -R "$repo_root/skills/playwright-my-chrome" "$case_dir/skill"
  /bin/rm "$case_dir/skill/cli/package-lock.json"
  run_capture "$case_dir/skill/scripts/playwright-my-chrome.sh" doctor
  assert_status 2
  assert_contains "$output" "lockfile is missing or unreadable"
  [[ ! -s "$MOCK_CLI_LOG" ]] ||
    fail "missing lockfile path reached a Playwright CLI"
  pass_test "a missing CLI lockfile fails closed"
}

test_global_playwright_cli_is_ignored() {
  local global_cli=""

  setup_case
  set_normal_chrome 111
  /bin/mkdir -p "$HOME/.nvm/versions/node/v99.0.0/bin" "$case_dir/caller-bin"
  for global_cli in \
    "$HOME/.nvm/versions/node/v99.0.0/bin/playwright-cli" \
    "$case_dir/caller-bin/playwright-cli"; do
    /bin/cat >"$global_cli" <<SCRIPT
#!/bin/sh
echo "\$0" >>"$case_dir/global-cli.log"
echo "$locked_cli_version"
SCRIPT
    /bin/chmod +x "$global_cli"
  done
  remove_private_cli
  PATH="$case_dir/caller-bin:$PATH" run_capture "$wrapper" connect
  assert_status 2
  assert_contains "$output" "private Playwright CLI is not installed"

  run_capture "$wrapper" setup
  assert_status 0
  PATH="$case_dir/caller-bin:$PATH" run_capture "$wrapper" connect
  assert_status 0
  assert_file_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -e "$case_dir/global-cli.log" ]] ||
    fail "the wrapper ran a global playwright-cli: $(<"$case_dir/global-cli.log")"
  pass_test "a global playwright-cli on PATH or in nvm is never run"
}

test_hung_setup_times_out_and_cleans_up() {
  setup_case
  remove_private_cli
  export MOCK_NPM_MODE="hang"
  export PLAYWRIGHT_MY_CHROME_TEST_SETUP_TIMEOUT_ATTEMPTS=3
  run_capture "$wrapper" setup
  assert_status 1
  assert_contains "$output" "npm ci timed out"
  assert_process_gone "$(<"$MOCK_NPM_PID_FILE")"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli" ]] ||
    fail "timed-out setup left a private CLI directory"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock" ]] ||
    fail "timed-out setup kept the wrapper lock"
  assert_no_setup_leftovers
  pass_test "a hung npm ci times out, is killed, and leaves nothing behind"
}

test_interrupted_setup_exits_promptly() {
  local expected_status=""
  local output_file=""
  local signal_name=""
  local wait_attempt=0
  local wrapper_pid=""

  for signal_name in TERM INT; do
    setup_case
    remove_private_cli
    output_file="$case_dir/setup.out"
    export MOCK_NPM_MODE="hang"
    # Bash starts a background job with SIGINT ignored. Perl restores the
    # default, so the wrapper gets INT as from a terminal.
    /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' \
      "$wrapper" setup >"$output_file" 2>&1 &
    wrapper_pid=$!
    wait_for_file "$MOCK_NPM_PID_FILE" "$wrapper_pid"
    kill "-$signal_name" "$wrapper_pid"
    wait_attempt=0
    while kill -0 "$wrapper_pid" 2>/dev/null; do
      wait_attempt=$((wait_attempt + 1))
      if (( wait_attempt > 50 )); then
        kill -KILL "$wrapper_pid" "$(<"$MOCK_NPM_PID_FILE")" 2>/dev/null || true
        fail "setup ignored $signal_name for more than 5 seconds"
      fi
      sleep 0.1
    done
    set +e
    wait "$wrapper_pid"
    status=$?
    set -e
    output="$(<"$output_file")"
    expected_status=143
    [[ "$signal_name" == "INT" ]] && expected_status=130
    assert_status "$expected_status"
    assert_process_gone "$(<"$MOCK_NPM_PID_FILE")"
    [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock" ]] ||
      fail "interrupted setup kept the wrapper lock"
    assert_no_setup_leftovers
    run_capture "$wrapper" ensure
    assert_status 2
  done
  pass_test "TERM or INT during npm ci kills it, releases the lock, and cleans up"
}

test_unsafe_private_cli_dir_fails_closed() {
  local outside=""

  setup_case
  set_normal_chrome 111
  outside="$case_dir/outside-cli"
  /bin/mv "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli" "$outside"
  /bin/ln -s "$outside" "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  for command_name in doctor connect setup; do
    run_capture "$wrapper" "$command_name"
    assert_status 6
    assert_contains "$output" "SECURITY: The private Playwright CLI must be a directory"
  done
  [[ ! -s "$MOCK_CLI_LOG" && ! -s "$MOCK_SECURITY_LOG" && ! -s "$MOCK_NPM_LOG" ]] ||
    fail "a symlinked private CLI was run, read the token, or was reinstalled"
  [[ -f "$outside/node_modules/@playwright/cli/playwright-cli.js" ]] ||
    fail "setup changed the symlink target"

  /bin/rm "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  /bin/mv "$outside" "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  /bin/chmod 755 "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  run_capture "$wrapper" connect
  assert_status 6
  pass_test "a symlinked or non-private CLI directory fails closed with exit 6"
}

test_setup_removes_abandoned_staging() {
  local outside=""

  setup_case
  outside="$case_dir/outside-staging"
  /bin/mkdir -m 700 "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/.cli-setup.abandoned"
  printf '%s\n' "partial" >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/.cli-setup.abandoned/file"
  /bin/mkdir -m 700 "$outside"
  printf '%s\n' "keep" >"$outside/keep.txt"
  /bin/ln -s "$outside" "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/.cli-setup.linked"
  run_capture "$wrapper" setup
  assert_status 0
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/.cli-setup.abandoned" ]] ||
    fail "setup kept an abandoned staging directory"
  assert_contains "$output" "Left an unexpected setup path in place"
  [[ "$(<"$outside/keep.txt")" == "keep" ]] ||
    fail "setup followed a symlinked staging path"
  pass_test "setup removes abandoned staging directories and skips symlinks"
}

test_incomplete_private_cli_requires_setup() {
  setup_case
  set_normal_chrome 111
  /usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/playwright" -depth -delete
  run_capture "$wrapper" doctor
  assert_contains "$output" "private CLI is incomplete or was changed after setup"
  : >"$MOCK_SECURITY_LOG"
  run_capture "$wrapper" connect
  assert_status 2
  [[ ! -s "$MOCK_SECURITY_LOG" ]] ||
    fail "incomplete private CLI path read the Keychain token"
  run_capture "$wrapper" setup
  assert_status 0
  assert_contains "$output" "Installed @playwright/cli $locked_cli_version"
  run_capture "$wrapper" doctor
  assert_contains "$output" "compatibility: supported (requires $locked_cli_version)"
  pass_test "a private CLI missing a locked package is reinstalled by setup"
}

test_help_prints_wrapper_usage_before_setup() {
  setup_case
  remove_private_cli
  for help_arguments in "" "--help" "-h" "goto --help"; do
    # shellcheck disable=SC2086
    run_capture "$wrapper" $help_arguments
    assert_status 0
    assert_contains "$output" "setup                   install the skill's private Playwright CLI"
    assert_contains "$output" "Playwright CLI commands are listed here after:"
  done
  [[ ! -s "$MOCK_CLI_LOG" ]] || fail "help ran a missing private CLI"

  run_capture "$wrapper" setup
  run_capture "$wrapper" --help
  assert_status 0
  assert_contains "$output" "Wrapper commands:"
  assert_file_contains "$MOCK_CLI_LOG" "--help"
  pass_test "help always prints wrapper usage and forwards only to a supported CLI"
}

test_setup_refuses_while_session_is_attached() {
  local copied_wrapper=""

  setup_case
  set_normal_chrome 111
  copy_skill_with_locked_version "0.1.999"
  copied_wrapper="$case_dir/skill/scripts/playwright-my-chrome.sh"
  printf '%s\n' "ready" >"$MOCK_SESSION_STATE_FILE"
  run_capture "$copied_wrapper" setup
  assert_status 1
  assert_contains "$output" "Setup never detaches on its own"
  [[ ! -s "$MOCK_NPM_LOG" ]] || fail "setup ran npm while the session was attached"
  assert_file_not_contains "$MOCK_CLI_LOG" "detach"

  run_capture "$copied_wrapper" disconnect
  assert_status 0
  assert_file_contains "$MOCK_CLI_LOG" "detach"
  run_capture "$copied_wrapper" setup
  assert_status 0
  assert_contains "$output" "Installed @playwright/cli 0.1.999"
  pass_test "setup refuses while attached and the old copy can still disconnect"
}

test_cleanup_plan_names_no_global_cli() {
  setup_case
  printf '%s\n' "ready" >"$MOCK_SESSION_STATE_FILE"
  run_capture "$wrapper" cleanup-plan
  assert_status 0
  assert_contains "$output" "safe action: detach it through the tool that owns it"
  assert_not_contains "$output" "playwright-cli"
  pass_test "cleanup-plan gives no global playwright-cli instruction"
}

test_version_prints_only_the_private_cli_version() {
  local flag=""

  setup_case
  for flag in --version -v; do
    run_capture "$wrapper" "$flag"
    assert_status 0
    [[ "$output" == "$locked_cli_version" ]] ||
      fail "$flag printed more than the version: $output"
  done
  remove_private_cli
  : >"$MOCK_CLI_LOG"
  for flag in --version -v; do
    run_capture "$wrapper" "$flag"
    assert_status 2
    assert_contains "$output" "$(printf '%q setup' "$wrapper")"
    assert_not_contains "$output" "Wrapper commands:"
  done
  [[ ! -s "$MOCK_CLI_LOG" ]] || fail "--version ran a missing private CLI"
  pass_test "--version prints only the version, or exits 2 before setup"
}

test_malformed_stored_token_is_refused_before_attach() {
  local stored_token=""

  for stored_token in \
    "PLAYWRIGHT_MCP_EXTENSION_TOKEN=TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" \
    "TEST_ONLY_short" \
    "TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456!"; do
    setup_case
    set_normal_chrome 111
    printf '%s\n' "$stored_token" >"$MOCK_KEYCHAIN_TOKEN_FILE"
    run_capture "$wrapper" connect
    assert_status 3
    assert_contains "$output" "missing or malformed in macOS Keychain"
    assert_contains "$output" \
      "store-extension-token.sh --migrate-from-service playwright-my-chrome.extension-token"
    assert_not_contains "$output" "$stored_token"
    assert_not_contains "$output" "TEST_ONLY_"
    assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  done

  printf '%s\n' "PLAYWRIGHT_MCP_EXTENSION_TOKEN=TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" \
    >"$MOCK_KEYCHAIN_TOKEN_FILE"
  run_capture "$store_token" --migrate-from-service playwright-my-chrome.extension-token
  assert_status 0
  run_capture "$wrapper" connect
  assert_status 0
  assert_file_contains "$MOCK_CLI_LOG" "attach-token-present"
  pass_test "a prefixed or malformed stored token exits 3 before attach and can be repaired"
}

test_setup_refuses_attached_incompatible_session() {
  setup_case
  copy_skill_with_locked_version "0.1.999"
  printf '%s\n' "ready" >"$MOCK_SESSION_STATE_FILE"
  export MOCK_SESSION_COMPATIBLE="false"
  run_capture "$case_dir/skill/scripts/playwright-my-chrome.sh" setup
  assert_status 1
  assert_contains "$output" "Setup never detaches on its own"
  [[ ! -s "$MOCK_NPM_LOG" ]] || fail "setup ran npm under an attached, incompatible session"
  pass_test "setup refuses a session that is attached but reported incompatible"
}

test_setup_with_unreadable_session_checks_for_a_live_daemon() {
  local daemon_path=""
  local physical_runtime=""

  setup_case
  copy_skill_with_locked_version "0.1.999"
  /usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/@playwright/cli" -depth -delete
  physical_runtime="$(cd -P "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" && pwd -P)"
  daemon_path="$physical_runtime/cli/node_modules/playwright-core/lib/entry/cliDaemon.js"
  printf '4242 /usr/local/bin/node %s mychrome --extension\n' "$daemon_path" \
    >"$MOCK_PS_OUTPUT_FILE"
  run_capture "$case_dir/skill/scripts/playwright-my-chrome.sh" setup
  assert_status 1
  assert_contains "$output" "daemon from the private CLI is still running (pid 4242)"
  printf '4343 node %s/cli/node_modules/standin.js\n' "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" \
    >"$MOCK_PS_OUTPUT_FILE"
  run_capture "$case_dir/skill/scripts/playwright-my-chrome.sh" setup
  assert_status 1
  assert_contains "$output" "(pid 4343)"
  [[ ! -s "$MOCK_NPM_LOG" ]] || fail "setup replaced a CLI that a live daemon runs from"

  printf '%s\n' \
    "5555 /usr/bin/awk -v logical=$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/ {print}" \
    "5556 /usr/bin/grep -F $physical_runtime/cli/node_modules/" \
    "5557 /bin/cat $daemon_path" \
    "5558 /bin/bash -c ps -axo pid=,command= | awk -v physical=$physical_runtime/cli/node_modules/" \
    "5559 /usr/bin/awk PRIVATE_CLI_LOGICAL=$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/" \
    >"$MOCK_PS_OUTPUT_FILE"
  run_capture "$case_dir/skill/scripts/playwright-my-chrome.sh" setup
  assert_status 0
  assert_contains "$output" "Installed @playwright/cli 0.1.999"
  pass_test "setup on a damaged copy refuses only for a node process running from it"
}

test_connect_rechecks_the_cli_under_the_lock() {
  local holder_pid=""
  local output_file=""
  local wrapper_pid=""

  setup_case
  set_normal_chrome 111
  output_file="$case_dir/connect.out"
  /bin/sleep 60 &
  holder_pid=$!
  /bin/mkdir -m 700 "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock"
  printf '%s\n' "$holder_pid" >"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock/pid"
  /bin/chmod 600 "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/ensure.lock/pid"
  "$wrapper" connect >"$output_file" 2>&1 &
  wrapper_pid=$!
  # Only the lock wait runs sleep as a direct child of the wrapper. This loop
  # waits for that.
  until /usr/bin/pgrep -P "$wrapper_pid" -x sleep >/dev/null; do
    kill -0 "$wrapper_pid" 2>/dev/null || fail "connect exited before it waited for the lock"
    sleep 0.05
  done
  printf '\n' >>"$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/package-lock.json"
  kill "$holder_pid"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 2
  assert_contains "$output" "was installed from another skill release's lockfile"
  assert_file_not_contains "$MOCK_CLI_LOG" "--json attach"
  [[ ! -s "$MOCK_SECURITY_LOG" ]] || fail "connect read the token after the CLI changed"
  pass_test "connect checks the CLI again after it takes the lock"
}

test_interrupted_swap_restores_the_previous_cli() {
  local output_file=""
  local wrapper_pid=""

  setup_case
  copy_skill_with_locked_version "0.1.999"
  output_file="$case_dir/setup.out"
  export MOCK_MV_HANG_TARGET="$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  "$case_dir/skill/scripts/playwright-my-chrome.sh" setup >"$output_file" 2>&1 &
  wrapper_pid=$!
  wait_for_file "$MOCK_MV_PID_FILE" "$wrapper_pid"
  [[ ! -e "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli" ]] ||
    fail "the test did not pause setup between its two moves"
  kill -TERM "$wrapper_pid"
  kill -TERM "$(<"$MOCK_MV_PID_FILE")"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 143
  unset MOCK_MV_HANG_TARGET
  assert_no_setup_leftovers
  run_capture "$wrapper" doctor
  assert_contains "$output" "compatibility: supported (requires $locked_cli_version)"
  pass_test "an interrupt between the two setup moves restores the previous CLI"
}

test_node_resolution_skips_versions_below_the_minimum() {
  local new_node_dir=""
  local old_node_dir=""

  setup_case
  new_node_dir="$HOME/.nvm/versions/node/v$(node -p 'process.versions.node')/bin"
  old_node_dir="$HOME/.nvm/versions/node/v20.0.0/bin"
  /bin/mkdir -p "$new_node_dir" "$old_node_dir"
  /bin/ln -s "$PLAYWRIGHT_MY_CHROME_NODE" "$new_node_dir/node"
  /bin/cat >"$old_node_dir/node" <<SCRIPT
#!/bin/sh
echo ran >>"$case_dir/old-node.log"
echo 20.0.0
SCRIPT
  /bin/chmod +x "$old_node_dir/node"
  /usr/bin/touch -t 203001010000 "$old_node_dir/node"
  PLAYWRIGHT_MY_CHROME_NODE="" run_capture "$wrapper" doctor
  assert_status 0
  assert_contains "$output" "compatibility: supported"
  [[ ! -e "$case_dir/old-node.log" ]] || fail "the wrapper ran a Node.js below the minimum"

  PLAYWRIGHT_MY_CHROME_NODE="$old_node_dir/node" run_capture "$wrapper" doctor
  assert_status 1
  assert_contains "$output" "Node.js 20.0.0 is older than the required 22.20.0"
  pass_test "node resolution skips a Node.js below the engines minimum"
}

test_setup_fails_closed_when_the_process_list_fails() {
  setup_case
  copy_skill_with_locked_version "0.1.999"
  /usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/@playwright/cli" -depth -delete
  export MOCK_PS_MODE="fail"
  run_capture "$case_dir/skill/scripts/playwright-my-chrome.sh" setup
  assert_status 1
  assert_contains "$output" "Could not inspect the process list"
  [[ ! -s "$MOCK_NPM_LOG" ]] || fail "setup treated a failed process list as proof of no daemon"
  pass_test "setup fails closed when it cannot inspect the process list"
}

test_setup_never_runs_a_rejected_copy() {
  setup_case
  /usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli/node_modules/playwright" -depth -delete
  run_capture "$wrapper" setup
  assert_status 0
  [[ "$(<"$MOCK_CLI_LOG")" == "--version" ]] ||
    fail "setup ran more than the staged copy's --version: $(<"$MOCK_CLI_LOG")"
  pass_test "setup runs no code from a copy that failed the intact check"
}

test_failed_rollback_keeps_the_previous_copy() {
  local output_file=""
  local wrapper_pid=""

  setup_case
  copy_skill_with_locked_version "0.1.999"
  output_file="$case_dir/setup.out"
  export MOCK_MV_HANG_TARGET="$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR/cli"
  export MOCK_MV_FAIL_RESTORE=1
  "$case_dir/skill/scripts/playwright-my-chrome.sh" setup >"$output_file" 2>&1 &
  wrapper_pid=$!
  wait_for_file "$MOCK_MV_PID_FILE" "$wrapper_pid"
  kill -TERM "$wrapper_pid"
  kill -TERM "$(<"$MOCK_MV_PID_FILE")"
  set +e
  wait "$wrapper_pid"
  status=$?
  set -e
  output="$(<"$output_file")"
  assert_status 143
  assert_contains "$output" "Could not restore the previous private Playwright CLI. It is kept at"
  [[ -n "$(/usr/bin/find "$PLAYWRIGHT_MY_CHROME_RUNTIME_DIR" -path '*/.cli-setup.*/previous/node_modules/@playwright/cli/playwright-cli.js' -print -quit)" ]] ||
    fail "cleanup deleted the only usable copy after a failed rollback"
  pass_test "a failed rollback keeps the staging directory and the previous copy"
}

test_token_repair_command_quotes_the_service() {
  setup_case
  set_normal_chrome 111
  export PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE="my token service"
  printf '%s\n' "PLAYWRIGHT_MCP_EXTENSION_TOKEN=TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" \
    >"$MOCK_KEYCHAIN_TOKEN_FILE"
  run_capture "$wrapper" connect
  unset PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE
  assert_status 3
  assert_contains "$output" '--migrate-from-service my\ token\ service'
  pass_test "the token repair command shell-escapes the Keychain service"
}

printed_command() {
  printf '%s\n' "$output" | /usr/bin/sed -n 's/^  //p' | /usr/bin/sed -n "${1}p"
}

run_printed_in_zsh() {
  run_capture /bin/zsh -f -c "$1"
}

test_printed_commands_work_from_a_path_with_spaces() {
  local spaced_skill=""
  local spaced_wrapper=""

  setup_case
  spaced_skill="$case_dir/skill dir/playwright my chrome"
  /bin/mkdir -p "${spaced_skill%/*}"
  /bin/cp -R "$repo_root/skills/playwright-my-chrome" "$spaced_skill"
  spaced_wrapper="$spaced_skill/scripts/playwright-my-chrome.sh"
  export PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE="my token service"
  remove_private_cli

  run_capture "$spaced_wrapper" connect
  assert_status 2
  run_printed_in_zsh "$(printed_command 1)"
  assert_status 0
  assert_contains "$output" "Installed @playwright/cli"

  run_capture "$spaced_wrapper" connect
  assert_status 5
  run_printed_in_zsh "$(printed_command 1)"
  assert_status 5
  assert_contains "$output" "Normal user Chrome is not already running"

  set_normal_chrome 111
  printf '%s\n' "PLAYWRIGHT_MCP_EXTENSION_TOKEN=TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" \
    >"$MOCK_KEYCHAIN_TOKEN_FILE"
  run_capture "$spaced_wrapper" connect
  assert_status 3
  run_printed_in_zsh "$(printed_command 1)"
  assert_status 0
  assert_contains "$output" "copied to the configured Keychain service"

  printf '%s\n' "TEST_ONLY_bad" >"$MOCK_KEYCHAIN_TOKEN_FILE"
  run_capture "$spaced_wrapper" connect
  assert_status 3
  printf '%s\n' "TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456" >"$MOCK_CLIPBOARD_FILE"
  run_printed_in_zsh "$(printed_command 2)"
  assert_status 0
  assert_contains "$output" "stored in macOS Keychain; clipboard cleared"

  run_capture "$spaced_wrapper" ensure
  assert_status 4
  run_printed_in_zsh "$(printed_command 1)"
  assert_status 0
  assert_contains "$output" "ready (attached session 'mychrome')"

  copy_skill_with_locked_version "0.1.999" "$case_dir/other skill"
  run_capture "$case_dir/other skill/scripts/playwright-my-chrome.sh" setup
  assert_status 1
  run_printed_in_zsh "$(printed_command 1)"
  unset PLAYWRIGHT_MY_CHROME_KEYCHAIN_SERVICE
  assert_status 0
  assert_contains "$output" "Detached Playwright session 'mychrome'"
  pass_test "every printed command runs through zsh from a path with spaces"
}

test_missing_chrome_refuses_before_token_read
test_ambiguous_chrome_refuses_before_token_read
test_successful_connect_uses_stable_existing_chrome
test_pid_change_during_attach_fails_closed
test_added_pid_during_attach_fails_closed
test_process_token_during_attach_fails_closed
test_pid_change_before_attach_never_invokes_attach
test_failed_attach_suppresses_token_and_scrubs_artifacts
test_hung_attach_is_terminated_and_scrubbed
test_hung_attach_reports_detach_failure
test_interrupted_attach_terminates_child_and_recovers
test_interrupted_post_attach_validation_recovers
test_unsupported_cli_version_blocks_browser_commands
test_unsupported_cli_version_blocks_disconnect
test_unsafe_commands_are_blocked_locally
test_symlink_lock_cannot_delete_outside_pid
test_disconnect_preserves_normal_chrome_pid
test_store_token_uses_keychain_and_clears_clipboard
test_doctor_reports_version_compatibility
test_traversal_metadata_cannot_escape_runtime
test_symlink_metadata_cannot_modify_target
test_setup_installs_from_shipped_lock_without_scripts
test_setup_is_idempotent
test_failed_setup_leaves_no_partial_copy
test_missing_private_cli_refuses_before_browser_access
test_new_lock_version_requires_setup_and_replaces_copy
test_missing_lock_fails_closed
test_global_playwright_cli_is_ignored
test_hung_setup_times_out_and_cleans_up
test_interrupted_setup_exits_promptly
test_unsafe_private_cli_dir_fails_closed
test_setup_removes_abandoned_staging
test_incomplete_private_cli_requires_setup
test_help_prints_wrapper_usage_before_setup
test_setup_refuses_while_session_is_attached
test_cleanup_plan_names_no_global_cli
test_version_prints_only_the_private_cli_version
test_malformed_stored_token_is_refused_before_attach
test_setup_refuses_attached_incompatible_session
test_setup_with_unreadable_session_checks_for_a_live_daemon
test_setup_fails_closed_when_the_process_list_fails
test_setup_never_runs_a_rejected_copy
test_failed_rollback_keeps_the_previous_copy
test_token_repair_command_quotes_the_service
test_printed_commands_work_from_a_path_with_spaces
test_connect_rechecks_the_cli_under_the_lock
test_interrupted_swap_restores_the_previous_cli
test_node_resolution_skips_versions_below_the_minimum

cleanup_case
printf 'All %d behavior tests passed.\n' "$passed"
