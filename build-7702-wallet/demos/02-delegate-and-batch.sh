#!/usr/bin/env bash
# Delegate the EOA to BatchExecutor, then atomically run approve+transfer+transfer
# in one transaction signed by the EOA itself.
set -euo pipefail
source .env

USDC=${USDC:?}
USER_ADDR=${USER_ADDR:?}
USER_PK=${USER_PK:?}
BATCHER=${BATCHER:?}
RECIPIENT=${RECIPIENT:-0x000000000000000000000000000000000000dEaD}

# 1. Sign and send the 7702 authorization tuple (sender = EOA itself).
python relayer/auth_tx_cli.py delegate \
  --delegate "$BATCHER" --user-pk "$USER_PK"

# 2. Build the batch call data and call the EOA (which now points at BatchExecutor).
APPROVE=$(cast calldata "approve(address,uint256)" "$RECIPIENT" 100000000)
XFER1=$(cast calldata "transfer(address,uint256)"   "$RECIPIENT" 1000000)
XFER2=$(cast calldata "transfer(address,uint256)"   "$RECIPIENT" 1000000)

BATCH_CALLDATA=$(cast calldata "executeBatch((address,uint256,bytes)[])" \
  "[($USDC,0,$APPROVE),($USDC,0,$XFER1),($USDC,0,$XFER2)]")

cast send "$USER_ADDR" "$BATCH_CALLDATA" \
  --private-key "$USER_PK" --rpc-url "$RPC_URL"

echo "expect: 1 tx hash, 1 gas payment, 1 nonce — two USDC transfers + 1 approve (delegation setup is separate)."
