#!/usr/bin/env bash
# Revoke EIP-7702 delegation by signing an authorization to the zero address.
# After the next block, EOA code is empty; a plain call may succeed without execution.
set -euo pipefail
source .env

USER_ADDR=${USER_ADDR:?}
USER_PK=${USER_PK:?}

echo "before:"
cast code "$USER_ADDR" --rpc-url "$RPC_URL"

python relayer/auth_tx_cli.py revoke --user-pk "$USER_PK"

sleep 2
echo "after:"
cast code "$USER_ADDR" --rpc-url "$RPC_URL"

echo "expect: '0x' — code is empty, storage at the EIP-7201 slot is preserved but unreachable."
