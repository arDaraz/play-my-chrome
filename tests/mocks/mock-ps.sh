#!/usr/bin/env bash
set -euo pipefail

output_file="${MOCK_PS_OUTPUT_FILE:?MOCK_PS_OUTPUT_FILE is required}"

if [[ "${MOCK_PS_MODE:-stable}" == "fail" ]]; then
  echo "mock ps failed" >&2
  exit 1
fi
if [[ " $* " == *" pid=,command= "* ]]; then
  /bin/cat "$output_file"
else
  /usr/bin/sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' "$output_file"
fi
