#!/usr/bin/env bash
# Add a session key scoped to USDC for 1 hour, use it to transfer, then revoke.
set -euo pipefail
source .env

USDC=${USDC:?}
USER_ADDR=${USER_ADDR:?}
USER_PK=${USER_PK:?}
SESSION_PK=${SESSION_PK:?}    # an ephemeral key, e.g. generated for this demo
RECIPIENT=${RECIPIENT:-0x000000000000000000000000000000000000dEaD}

SESSION_ADDR=$(cast wallet address --private-key "$SESSION_PK")
VALID_UNTIL=$(( $(date +%s) + 3600 ))

# 1. EOA adds session key (this call must come from the EOA itself).
ADD_DATA=$(cast calldata "addSessionKey(address,uint48,address)" \
  "$SESSION_ADDR" "$VALID_UNTIL" "$USDC")
cast send "$USER_ADDR" "$ADD_DATA" \
  --private-key "$USER_PK" --rpc-url "$RPC_URL"

# 2. Session key signs an Execute via the SessionExecute typehash; any sponsor sends it.
#    (Reuses relayer/relayer.py with --user-pk = SESSION_PK; session typehash variant
#     is wired in relayer/session_relay.py — see deep-dive/session-key-design.md.)
DATA=$(cast calldata "transfer(address,uint256)" "$RECIPIENT" 2000000)
python relayer/session_relay.py run \
  --eoa "$USER_ADDR" --target "$USDC" --data "$DATA" \
  --session-pk "$SESSION_PK" --relayer-pk "$PRIVATE_KEY"

# 3. Revoke.
REM_DATA=$(cast calldata "removeSessionKey(address)" "$SESSION_ADDR")
cast send "$USER_ADDR" "$REM_DATA" \
  --private-key "$USER_PK" --rpc-url "$RPC_URL"

if python relayer/session_relay.py run --eoa "$USER_ADDR" --target "$USDC" --data "$DATA" --session-pk "$SESSION_PK" --relayer-pk "$PRIVATE_KEY"; then
  echo "ERROR: revoked key succeeded"; exit 1
fi
echo "Revoked session rejected (use record_demo.py to assert the exact error)."
