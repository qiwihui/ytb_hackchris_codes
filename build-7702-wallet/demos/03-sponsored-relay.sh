#!/usr/bin/env bash
# Sponsored execution: EOA signs offline (no ETH), relayer pays the gas.
set -euo pipefail
source .env

USDC=${USDC:?}
USER_ADDR=${USER_ADDR:?}
USER_PK=${USER_PK:?}
DELEGATE=${DELEGATE:?}        # EOADelegate address
RECIPIENT=${RECIPIENT:-0x000000000000000000000000000000000000dEaD}

# 0. Prereq: USER_ADDR is already delegated to DELEGATE (see 02-delegate-and-batch.sh
#    or relayer/auth_tx_cli.py delegate).

# Set the main delegate explicitly (separate setup transaction).
python relayer/auth_tx_cli.py delegate --delegate "$DELEGATE" --user-pk "$USER_PK"
# Use record_demo.py for verified zero-ETH before/after balances.
# 1. EOA signs Execute(USDC, 0, transfer(RECIPIENT, 5_000_000), nonce=0, chainId)
DATA=$(cast calldata "transfer(address,uint256)" "$RECIPIENT" 5000000)
SIG_JSON=$(python relayer/relayer.py sign \
  --target "$USDC" --data "$DATA" --user-pk "$USER_PK")
SIG=$(echo "$SIG_JSON" | python -c "import sys,json;print(json.load(sys.stdin)['sig'])")

# 2. Relayer (different key, has ETH) broadcasts and pays gas.
python relayer/relayer.py relay \
  --eoa "$USER_ADDR" --target "$USDC" --data "$DATA" --sig "$SIG" \
  --relayer-pk "$PRIVATE_KEY"

echo "expect: USER_ADDR ETH balance unchanged. Relayer ETH balance drops."
