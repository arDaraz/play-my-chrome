#!/usr/bin/env bash
set -euo pipefail

# The first move into MOCK_MV_HANG_TARGET waits for TERM, so a test can
# interrupt setup between its two moves.
if [[ -n "${MOCK_MV_HANG_TARGET:-}" && "${!#}" == "$MOCK_MV_HANG_TARGET" &&
  ! -e "${MOCK_MV_PID_FILE:?MOCK_MV_PID_FILE is required}" ]]; then
  printf '%s\n' "$$" >"$MOCK_MV_PID_FILE"
  trap 'exit 143' TERM
  while :; do
    :
  done
fi
# With MOCK_MV_FAIL_RESTORE set, a later move into that path fails, so a test
# can make the rollback fail.
if [[ -n "${MOCK_MV_FAIL_RESTORE:-}" && "${!#}" == "${MOCK_MV_HANG_TARGET:-}" ]]; then
  exit 1
fi
exec /bin/mv "$@"
