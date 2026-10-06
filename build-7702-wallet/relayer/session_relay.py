"""Submit a personal-message session signature. Local teaching implementation."""
import json
import os
import click
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3
from dotenv import load_dotenv

load_dotenv()
SESSION_TYPE = 'SessionExecute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)'

def session_signature(w3, eoa, target, data, key, value=0):
    nonce = int.from_bytes(w3.eth.call({'to': eoa, 'data': Web3.keccak(text='nonce()')[:4]}), 'big')
    sh = Web3.keccak(w3.codec.encode(
        ['bytes32', 'address', 'uint256', 'bytes32', 'uint256', 'uint256', 'address'],
        [Web3.keccak(text=SESSION_TYPE), target, value, Web3.keccak(data), nonce, w3.eth.chain_id, eoa]))
    return Account.sign_message(encode_defunct(primitive=sh), key).signature

@click.group()
def cli():
    pass

@cli.command('run')
@click.option('--eoa', required=True)
@click.option('--target', required=True)
@click.option('--data', required=True)
@click.option('--session-pk', required=True, envvar='SESSION_PK')
@click.option('--relayer-pk', required=True, envvar='PRIVATE_KEY')
@click.option('--rpc', default=lambda: os.getenv('RPC_URL', 'http://127.0.0.1:8545'))
def run(eoa, target, data, session_pk, relayer_pk, rpc):
    w3 = Web3(Web3.HTTPProvider(rpc))
    eoa, target = map(Web3.to_checksum_address, (eoa, target))
    data = bytes.fromhex(data.removeprefix('0x'))
    sig = session_signature(w3, eoa, target, data, session_pk)
    sender = Account.from_key(relayer_pk)
    payload = Web3.keccak(text='executeBySession(address,uint256,bytes,bytes)')[:4] + w3.codec.encode(
        ['address', 'uint256', 'bytes', 'bytes'], [target, 0, data, sig])
    tx = dict(to=eoa, data=payload, value=0, chainId=w3.eth.chain_id,
              nonce=w3.eth.get_transaction_count(sender.address), gas=500000,
              maxFeePerGas=w3.eth.gas_price*2+10**9, maxPriorityFeePerGas=10**9)
    signed = sender.sign_transaction(tx)
    receipt = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(signed.raw_transaction))
    click.echo(json.dumps(dict(hash=receipt.transactionHash.to_0x_hex(), status=receipt.status, gasUsed=receipt.gasUsed)))
    if receipt.status != 1:
        raise click.ClickException('session execution reverted')

if __name__ == '__main__':
    cli()
