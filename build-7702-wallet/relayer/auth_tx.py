"""Build and submit an EIP-7702 SET_CODE_TX_TYPE (0x04) transaction.

This is the minimum a wallet has to do to "install code" on an EOA:

    1. EOA signs an *authorization tuple*:  (chainId, delegate, nonce)
    2. A sender (can be the EOA itself, can be a sponsor) wraps the
       authorization into a type-4 transaction and broadcasts.
    3. After authorization processing, the EOA's `code` is `0xef0100 || delegate`
       and any call to the EOA executes `delegate`'s code in the EOA's
       storage namespace.

We use `eth_account.Account.sign_authorization` (eth-account >= 0.13).
"""
from __future__ import annotations

from typing import Optional

from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3


def sign_authorization(
    eoa: LocalAccount,
    chain_id: int,
    delegate: str,
    nonce: int,
) -> dict:
    """Return a signed (chain_id, delegate, nonce, y_parity, r, s) tuple.

    `nonce` is the EOA's transaction nonce at the time the authorization
    will be *executed*. If the EOA itself is the sender of the outer tx,
    nonce = current_nonce + 1 (since the outer tx consumes nonce first).
    If a sponsor sends the outer tx, nonce = current_nonce.
    """
    return eoa.sign_authorization(
        {"chainId": chain_id, "address": Web3.to_checksum_address(delegate), "nonce": nonce}
    )


def send_delegation_tx(
    w3: Web3,
    sender: LocalAccount,
    authorization: dict,
    to: Optional[str] = None,
    data: bytes = b"",
    value: int = 0,
) -> str:
    """Send a type-4 transaction that includes one authorization.

    `to` and `data` are the outer call payload — many wallets set
    `to = eoa` and `data = <first delegated call>` so execution can follow delegation in one transaction.
    A reverted execution does NOT roll back the delegation indicator.
    """
    if to is None:
        raise ValueError("type-4 requires a non-null destination")
    chain_id = w3.eth.chain_id
    nonce = w3.eth.get_transaction_count(sender.address)
    base_fee = w3.eth.get_block("pending").get("baseFeePerGas") or 0
    max_priority = w3.to_wei(1, "gwei")
    max_fee = base_fee * 2 + max_priority

    tx = {
        "type": 4,
        "chainId": chain_id,
        "nonce": nonce,
        "to": Web3.to_checksum_address(to) if to else None,
        "value": value,
        "data": data,
        "gas": 500_000,
        "maxFeePerGas": max_fee,
        "maxPriorityFeePerGas": max_priority,
        "accessList": [],
        "authorizationList": [authorization],
    }
    signed = sender.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    return tx_hash.hex()


def revoke_authorization(eoa: LocalAccount, chain_id: int, nonce: int) -> dict:
    """Revoking is just delegating to the zero address."""
    return sign_authorization(eoa, chain_id, "0x0000000000000000000000000000000000000000", nonce)
