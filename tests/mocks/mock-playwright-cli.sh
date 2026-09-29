#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_CLI_LOG:?MOCK_CLI_LOG is required}"
state_file="${MOCK_SESSION_STATE_FILE:?MOCK_SESSION_STATE_FILE is required}"
ps_output_file="${MOCK_PS_OUTPUT_FILE:?MOCK_PS_OUTPUT_FILE is required}"
chrome_executable="${PLAYWRIGHT_MY_CHROME_EXECUTABLE:?Chrome executable is required}"
runtime_dir="${PLAYWRIGHT_MY_CHROME_RUNTIME_DIR:?Runtime directory is required}"
version="${MOCK_CLI_VERSION:?MOCK_CLI_VERSION is required}"
arguments=" $* "

printf '%s\n' "$*" >>"$log_file"

if [[ "$arguments" == *" --version "* || "$arguments" == *" -v "* ]]; then
  printf '%s\n' "$version"
  exit 0
fi

if [[ "$arguments" == *" --json list "* ]]; then
  if [[ "${MOCK_CHANGE_PID_ON_LIST_ALL:-0}" == "1" &&
    "$arguments" == *" --all "* ]]; then
    printf '222 %s\n' "$chrome_executable" >"$ps_output_file"
  fi

  if [[ -f "$state_file" ]] && [[ "$(<"$state_file")" == "ready" ]]; then
    printf '{"browsers":[{"name":"mychrome","status":"open","attached":true,"compatible":%s,"browserType":"chrome","workspace":"%s"}]}\n' \
      "${MOCK_SESSION_COMPATIBLE:-true}" "$runtime_dir"
  else
    printf '{"browsers":[]}\n'
  fi
  exit 0
fi

if [[ "$arguments" == *" --json attach "* ]]; then
  if [[ -n "${PLAYWRIGHT_MCP_EXTENSION_TOKEN:-}" ]]; then
    printf '%s\n' "attach-token-present" >>"$log_file"
  else
    printf '%s\n' "attach-token-missing" >>"$log_file"
    exit 20
  fi

  case "${MOCK_ATTACH_MODE:-stable}" in
    stable)
      ;;
    pid-change)
      printf '222 %s\n' "$chrome_executable" >"$ps_output_file"
      ;;
    process-token)
      printf '111 %s %s?token=TEST_ONLY_TOKEN_abcdefghijklmnopqrstuvwxyz123456\n' \
        "$chrome_executable" \
        "chrome-extension://mmlmfjhmonkocbjadbfplnigmagldckm/connect.html" \
        >"$ps_output_file"
      ;;
    chrome-missing)
      : >"$ps_output_file"
      ;;
    add-pid)
      printf '111 %s\n222 %s\n' \
        "$chrome_executable" \
        "$chrome_executable" \
        >"$ps_output_file"
      ;;
    fail)
      printf 'attach failed for token %s\n' "$PLAYWRIGHT_MCP_EXTENSION_TOKEN" >&2
      exit 22
      ;;
    hang)
      if [[ -n "${MOCK_ATTACH_PID_FILE:-}" ]]; then
        printf '%s\n' "$$" >"$MOCK_ATTACH_PID_FILE"
      fi
      trap 'exit 143' TERM
      while :; do
        :
      done
      ;;
    *)
      printf 'Unknown MOCK_ATTACH_MODE: %s\n' "$MOCK_ATTACH_MODE" >&2
      exit 21
      ;;
  esac
  printf '%s\n' "ready" >"$state_file"
  printf '{"attached":true}\n'
  exit 0
fi

if [[ "$arguments" == *" tab-list "* ]]; then
  if [[ "${MOCK_TAB_LIST_MODE:-stable}" == "hang" ]]; then
    if [[ -n "${MOCK_TAB_LIST_PID_FILE:-}" ]]; then
      printf '%s\n' "$$" >"$MOCK_TAB_LIST_PID_FILE"
    fi
    trap 'exit 143' TERM
    while :; do
      :
    done
  fi
  printf '%s\n' \
    '- 0: [Playwright Extension](chrome-extension://mmlmfjhmonkocbjadbfplnigmagldckm/connect.html?token=TEST_ONLY_REDACTED)' \
    '- 1: (current) [about:blank](about:blank)'
  exit 0
fi

if [[ "$arguments" == *" tab-new "* ||
  "$arguments" == *" tab-select "* ]]; then
  exit 0
fi

if [[ "$arguments" == *" detach "* ]]; then
  if [[ -n "${PLAYWRIGHT_MCP_EXTENSION_TOKEN:-}" ]]; then
    printf '%s\n' "detach-token-present" >>"$log_file"
  else
    printf '%s\n' "detach-token-absent" >>"$log_file"
  fi
  if [[ "${MOCK_DETACH_MODE:-stable}" == "fail" ]]; then
    exit 23
  fi
  printf '%s\n' "missing" >"$state_file"
  exit 0
fi

printf '%s\n' "mock command completed"
