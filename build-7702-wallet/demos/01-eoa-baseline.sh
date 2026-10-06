#!/usr/bin/env bash
# Baseline: a pure EOA sending approve plus two transfers. No 7702.
# Use this as the "before" picture in the video.
set -euo pipefail
source .env

USDC=${USDC:?}
USER_ADDR=${USER_ADDR:?}
USER_PK=${USER_PK:?}
RECIPIENT=${RECIPIENT:-0x000000000000000000000000000000000000dEaD}

cast send "$USDC" "approve(address,uint256)" "$RECIPIENT" 100000000 --private-key "$USER_PK" --rpc-url "$RPC_URL"
for i in 1 2; do
  cast send "$USDC" "transfer(address,uint256)" "$RECIPIENT" 1000000 --private-key "$USER_PK" --rpc-url "$RPC_URL"
done

echo "expect: 3 separate transactions, 3 separate gas payments, 3 separate nonces."
