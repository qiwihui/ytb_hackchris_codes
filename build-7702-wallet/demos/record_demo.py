"""Isolated local-chain evidence for the episode. Never connects to a public RPC.

Usage: python demos/record_demo.py --output /path/to/evidence
Starts its own Anvil on port 18545 and always terminates it afterwards.
Keys are deterministic PUBLIC TEST KEYS (integers 1..4); never fund them.
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'relayer'))
from auth_tx import sign_authorization, send_delegation_tx
from relayer import _struct_hash
from session_relay import session_signature

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=ROOT/'evidence')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
events = []
def log(kind, **data):
    events.append(dict(kind=kind, **data))
    print(json.dumps(events[-1], ensure_ascii=False), flush=True)

anvil_log = (args.output/'anvil.log').open('w')
proc = subprocess.Popen(['anvil', '--hardfork', 'prague', '--port', '18545', '--host', '127.0.0.1', '--silent'],
                        stdout=anvil_log, stderr=subprocess.STDOUT)
try:
    w3 = Web3(Web3.HTTPProvider('http://127.0.0.1:18545'))
    for _ in range(60):
        if proc.poll() is not None:
            raise RuntimeError('Anvil exited; see anvil.log')
        if w3.is_connected(): break
        time.sleep(.2)
    assert w3.is_connected() and w3.eth.chain_id == 31337
    assert w3.eth.block_number == 0, 'refuse to use a pre-existing chain'
    sponsor, user, session, recipient = [Account.from_key(i.to_bytes(32,'big')) for i in range(1,5)]
    def rpc(method, params):
        result = w3.provider.make_request(method, params)
        if 'error' in result: raise RuntimeError(result['error'])
        return result['result']
    for a in (sponsor,user):rpc('anvil_setBalance',[a.address, hex(100*10**18)])
    log('environment', chainId=w3.eth.chain_id, anvil=subprocess.check_output(['anvil','--version'],text=True).strip(),
        web3=__import__('web3').__version__, user=user.address, sponsor=sponsor.address,
        recipient=recipient.address, session=session.address)
    def tx(key, to=None, data=b'', expected=1):
        d=dict(chainId=w3.eth.chain_id, nonce=w3.eth.get_transaction_count(key.address),
               gas=5000000, maxFeePerGas=w3.eth.gas_price*2+10**9,
               maxPriorityFeePerGas=10**9, value=0, data=data)
        if to:d['to']=to
        sig=key.sign_transaction(d)
        receipt=w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(sig.raw_transaction))
        log('receipt', hash=receipt.transactionHash.to_0x_hex(), status=receipt.status,
            gasUsed=receipt.gasUsed, sender=key.address, to=to)
        assert receipt.status==expected, receipt
        return receipt
    def deploy(file, name):
        a=json.loads((ROOT/'out'/file/f'{name}.json').read_text())
        r=tx(sponsor,data=a['bytecode']['object'])
        return w3.eth.contract(address=r.contractAddress,abi=a['abi'])
    batch=deploy('BatchExecutor.sol','BatchExecutor')
    wallet=deploy('EOADelegate.sol','EOADelegate')
    token=deploy('MockUSDC.sol','MockUSDC')
    account=w3.eth.contract(address=user.address,abi=wallet.abi)
    batch_account=w3.eth.contract(address=user.address,abi=batch.abi)
    def send(key, fn, expected=1):return tx(key,fn.address,fn._encode_transaction_data(),expected)
    def set_delegate(addr):
        auth=sign_authorization(user,w3.eth.chain_id,addr,w3.eth.get_transaction_count(user.address))
        h=send_delegation_tx(w3,sponsor,auth,to=user.address)
        r=w3.eth.wait_for_transaction_receipt(h)
        code=w3.eth.get_code(user.address)
        expected=b'' if int(addr,16)==0 else bytes.fromhex('ef0100'+addr[2:])
        assert r.status==1 and code==expected
        assert w3.eth.get_transaction(h).type==4
        log('delegation', hash=Web3.to_hex(h) if isinstance(h,bytes) else h, type=4,
            status=r.status, code=code.to_0x_hex())
    send(sponsor,token.functions.mint(user.address,1000_000000))
    # Compare business calls from identical token state. Setup is separate.
    snap=rpc('evm_snapshot',[])
    send(user,token.functions.approve(recipient.address,100_000000))
    send(user,token.functions.transfer(recipient.address,1_000000))
    send(user,token.functions.transfer(recipient.address,1_000000))
    baseline=token.functions.balanceOf(recipient.address).call()
    log('baseline', business_transactions=3, recipient_units=baseline)
    assert rpc('evm_revert',[snap])
    set_delegate(batch.address)
    calls=[(token.address,0,token.functions.approve(recipient.address,100_000000)._encode_transaction_data()),
           (token.address,0,token.functions.transfer(recipient.address,1_000000)._encode_transaction_data()),
           (token.address,0,token.functions.transfer(recipient.address,1_000000)._encode_transaction_data())]
    send(user,batch_account.functions.executeBatch(calls))
    assert token.functions.balanceOf(recipient.address).call()==baseline
    log('batch', business_transactions=1, setup_transactions=1, recipient_units=baseline)
    before=(token.functions.balanceOf(recipient.address).call(),token.functions.allowance(user.address,recipient.address).call())
    failing=[(token.address,0,token.functions.approve(recipient.address,3_000000)._encode_transaction_data()),
             calls[1],(token.address,0,token.functions.transfer(recipient.address,2000_000000)._encode_transaction_data())]
    send(user,batch_account.functions.executeBatch(failing),expected=0)
    after=(token.functions.balanceOf(recipient.address).call(),token.functions.allowance(user.address,recipient.address).call())
    assert before==after
    log('rollback', recipient_before=before[0],recipient_after=after[0],allowance_before=before[1],allowance_after=after[1])
    set_delegate(wallet.address)
    rpc('anvil_setBalance',[user.address,'0x0'])
    data=bytes.fromhex(token.functions.transfer(recipient.address,5_000000)._encode_transaction_data()[2:])
    sh=_struct_hash(token.address,0,data,account.functions.nonce().call(),w3.eth.chain_id,user.address)
    sig=user.sign_message(encode_defunct(primitive=sh)).signature
    b=(w3.eth.get_balance(user.address),w3.eth.get_balance(sponsor.address),token.functions.balanceOf(recipient.address).call())
    send(sponsor,account.functions.executeWithSig(token.address,0,data,sig))
    a=(w3.eth.get_balance(user.address),w3.eth.get_balance(sponsor.address),token.functions.balanceOf(recipient.address).call())
    assert b[0]==a[0]==0 and a[1]<b[1] and a[2]-b[2]==5_000000
    log('sponsored',user_eth_before=b[0],user_eth_after=a[0],sponsor_wei_before=b[1],sponsor_wei_after=a[1],
        recipient_before=b[2],recipient_after=a[2])
    send(sponsor,account.functions.executeWithSig(token.address,0,data,sig),expected=0)
    log('owner_replay',rejected=True)
    # Management is a separate paid user transaction, not part of zero-ETH demo.
    rpc('anvil_setBalance',[user.address,hex(10**18)])
    send(user,account.functions.addSessionKey(session.address,w3.eth.get_block('latest').timestamp+3600,token.address))
    sig=session_signature(w3,user.address,token.address,data,session.key)
    send(sponsor,account.functions.executeBySession(token.address,0,data,sig))
    log('session',status=1,nonce=account.functions.nonce().call())
    send(user,account.functions.removeSessionKey(session.address))
    sig=session_signature(w3,user.address,token.address,data,session.key)
    fn=account.functions.executeBySession(token.address,0,data,sig)
    try:fn.call({'from':sponsor.address})
    except Exception as ex:
        assert Web3.keccak(text='SessionKeyDisabled()')[:4].hex() in str(ex).replace('0x',''), str(ex)
    else:raise AssertionError('revoked session unexpectedly executable')
    send(sponsor,fn,expected=0)
    log('session_revoked',rejected=True,nonce=account.functions.nonce().call(),error='SessionKeyDisabled')
    slot=int('e34bdf1170507d0c3bb392e10bbb9ffadcd2cfe0328b0b655d1e95943c490100',16)
    prior=w3.eth.get_storage_at(user.address,slot)
    set_delegate('0x'+'00'*20)
    assert w3.eth.get_storage_at(user.address,slot)==prior
    log('revoked',code=w3.eth.get_code(user.address).to_0x_hex(),stored_nonce=int.from_bytes(prior,'big'),storage_preserved=True)
    log('result',passed=True)
finally:
    (args.output/'demo.json').write_text(json.dumps(events,ensure_ascii=False,indent=2)+'\n')
    proc.terminate()
    try:proc.wait(timeout=5)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()
    anvil_log.close()
