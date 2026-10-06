# Relayer

Two scripts, used together to demo sponsored execution on a 7702-delegated EOA.

| File | Purpose |
|------|---------|
| `auth_tx.py` | Helpers to sign an EIP-7702 authorization tuple and submit the type-4 SET_CODE_TX_TYPE transaction. |
| `relayer.py` | CLI for `sign` (EOA produces the 个人消息（非 EIP-712） sig over an `Execute(...)` struct) and `relay` (relayer broadcasts `executeWithSig` and pays gas). |

### Quickstart

```bash
pip install -r relayer/requirements.txt

# Terminal 1 — local prague chain (7702 enabled)
anvil --hardfork prague

# Terminal 2 — deploy EOADelegate, delegate the user EOA to it
forge script script/Delegate.s.sol --rpc-url $RPC_URL --broadcast

# Terminal 3 — sign an Execute struct as the EOA
python relayer/relayer.py sign \
  --target $USDC --data 0xa9059cbb...  --user-pk $USER_PK

# Terminal 3 — relayer pays gas, EOA pays nothing
python relayer/relayer.py relay \
  --eoa $USER_ADDR --target $USDC --data 0xa9059cbb... --sig 0x... \
  --relayer-pk $PRIVATE_KEY
```

The full demo lives in `demos/03-sponsored-relay.sh`.
