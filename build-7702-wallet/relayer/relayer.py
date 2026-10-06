"""Minimal sponsored relayer for EOADelegate.

A relayer is *just* an address with ETH that:

    1. holds the user's personal-message signature over (target, value, data, nonce, chainId)
    2. calls EOADelegate.executeWithSig on the user's EOA
    3. pays the gas

This file is intentionally < 200 lines. There is no queue, no policy engine,
no fee model — those are deep-dive topics in deep-dive/relayer-economics.md.

CLI:

    python relayer/relayer.py sign  --target 0xUSDC --data 0x... --to-private USER_PK
    python relayer/relayer.py relay --eoa 0xUSER --target 0xUSDC --data 0x... --sig 0x...
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import click
from dotenv import load_dotenv
from eth_account import Account
from eth_account.messages import encode_defunct
from rich.console import Console
from web3 import Web3

load_dotenv()
console = Console()

EXECUTE_TYPEHASH = Web3.keccak(
    text="Execute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)"
)


def _struct_hash(target: str, value: int, data: bytes, nonce: int, chain_id: int, account: str) -> bytes:
    return Web3.keccak(
        Web3().codec.encode(
            ["bytes32", "address", "uint256", "bytes32", "uint256", "uint256", "address"],
            [EXECUTE_TYPEHASH, Web3.to_checksum_address(target), value, Web3.keccak(data), nonce, chain_id, Web3.to_checksum_address(account)],
        )
    )


def _eth_signed_digest(struct_hash: bytes) -> bytes:
    return Web3.keccak(b"\x19Ethereum Signed Message:\n32" + struct_hash)


@click.group()
def cli() -> None:
    """Sponsored-relay helper for EOADelegate."""


@cli.command()
@click.option("--target", required=True)
@click.option("--data", required=True, help="0x-prefixed calldata")
@click.option("--value", default=0, type=int)
@click.option("--nonce", default=None, type=int, help="EOADelegate nonce, NOT the EOA tx nonce")
@click.option("--rpc", default=lambda: os.getenv("RPC_URL", "http://localhost:8545"))
@click.option("--user-pk", required=True, envvar="USER_PK")
def sign(target: str, data: str, value: int, nonce: int, rpc: str, user_pk: str) -> None:
    """Produce the EOA's personal-message signature over an Execute(...) struct."""
    w3 = Web3(Web3.HTTPProvider(rpc))
    chain_id = w3.eth.chain_id
    data_bytes = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    account = Account.from_key(user_pk).address
    if nonce is None:
        nonce = int.from_bytes(w3.eth.call({"to": account, "data": Web3.keccak(text="nonce()")[:4]}), "big")
    sh = _struct_hash(target, value, data_bytes, nonce, chain_id, account)
    digest = _eth_signed_digest(sh)
    # eth_account uses prefixed personal_sign by default; we built the prefix ourselves
    # already, so we sign the raw 32-byte hash.
    signed = Account._sign_hash(digest, user_pk)  # noqa: SLF001 — teaching-grade
    sig_hex = signed.signature.hex()
    click.echo(json.dumps({"chainId": chain_id, "nonce": nonce, "sig": "0x" + sig_hex.removeprefix("0x")}, indent=2))


@cli.command()
@click.option("--eoa", required=True, help="The delegated EOA address (this is `to`)")
@click.option("--target", required=True)
@click.option("--data", required=True)
@click.option("--sig", required=True)
@click.option("--value", default=0, type=int)
@click.option("--rpc", default=lambda: os.getenv("RPC_URL", "http://localhost:8545"))
@click.option("--relayer-pk", required=True, envvar="PRIVATE_KEY")
def relay(eoa: str, target: str, data: str, sig: str, value: int, rpc: str, relayer_pk: str) -> None:
    """Broadcast executeWithSig(target, value, data, sig) on the EOA."""
    w3 = Web3(Web3.HTTPProvider(rpc))
    relayer = Account.from_key(relayer_pk)
    data_bytes = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    sig_bytes = bytes.fromhex(sig[2:] if sig.startswith("0x") else sig)

    # selector for executeWithSig(address,uint256,bytes,bytes)
    selector = Web3.keccak(text="executeWithSig(address,uint256,bytes,bytes)")[:4]
    encoded = Web3().codec.encode(
        ["address", "uint256", "bytes", "bytes"],
        [Web3.to_checksum_address(target), value, data_bytes, sig_bytes],
    )
    tx = {
        "from": relayer.address,
        "to": Web3.to_checksum_address(eoa),
        "value": 0,
        "data": selector + encoded,
        "nonce": w3.eth.get_transaction_count(relayer.address),
        "chainId": w3.eth.chain_id,
        "gas": 500_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(1, "gwei"),
    }
    signed = relayer.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    console.print(f"[green]submitted[/green] {tx_hash.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    console.print(f"[bold]status[/bold] = {receipt.status}  gasUsed = {receipt.gasUsed}")
    if receipt.status != 1:
        raise click.ClickException("execution reverted")


if __name__ == "__main__":
    cli()
