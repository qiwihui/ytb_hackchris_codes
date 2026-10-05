#!/usr/bin/env bash
# 一键：编译 -> 起 anvil -> 跑端到端演示 -> 关 anvil
set -euo pipefail
cd "$(dirname "$0")"

forge build >/dev/null
anvil --silent --port 8545 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null' EXIT
sleep 1

(cd agent && [ -d node_modules ] || npm install --silent)
node agent/demo.mjs
