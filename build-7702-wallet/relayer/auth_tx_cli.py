"""Delegate/revoke on a chain supporting EIP-7702."""
import os
import click
from dotenv import load_dotenv
from eth_account import Account
from web3 import Web3
from auth_tx import sign_authorization, send_delegation_tx

load_dotenv()
@click.group()
def cli():
    pass

def submit(delegate, user_pk, rpc):
    w3 = Web3(Web3.HTTPProvider(rpc))
    user = Account.from_key(user_pk)
    auth = sign_authorization(user, w3.eth.chain_id, delegate, w3.eth.get_transaction_count(user.address)+1)
    txid = send_delegation_tx(w3, user, auth, to=user.address)
    receipt = w3.eth.wait_for_transaction_receipt(txid)
    expected = b'' if int(delegate, 16) == 0 else bytes.fromhex('ef0100'+delegate[2:])
    if receipt.status != 1 or w3.eth.get_code(user.address) != expected:
        raise click.ClickException('delegation state check failed')
    click.echo(f'tx={txid} code={w3.eth.get_code(user.address).to_0x_hex()}')

@cli.command()
@click.option('--delegate', required=True)
@click.option('--user-pk', required=True, envvar='USER_PK')
@click.option('--rpc', default=lambda: os.getenv('RPC_URL', 'http://127.0.0.1:8545'))
def delegate(delegate, user_pk, rpc):
    submit(delegate, user_pk, rpc)

@cli.command()
@click.option('--user-pk', required=True, envvar='USER_PK')
@click.option('--rpc', default=lambda: os.getenv('RPC_URL', 'http://127.0.0.1:8545'))
def revoke(user_pk, rpc):
    submit('0x'+'00'*20, user_pk, rpc)

if __name__ == '__main__':
    cli()
