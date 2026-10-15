#!/usr/bin/env bash

set -euo pipefail

node ./run-tests.js

# Smoke test: wrapper → Ruby → gem → JSON contract
output=$(./ollama-ps.sh)
state=$(echo "$output" | jq -r '.data.servers[0].state')
error=$(echo "$output" | jq -r '.data.servers[0].error')
if [[ "$state" != "online" && "$error" != "Cannot reach the server." ]]; then
  echo "FAIL: unexpected state=$state error=$error" >&2
  exit 1
else
  echo "SUCCESS: Running ollama-ps.sh worked, loaded ollama-ruby, created output."
fi
