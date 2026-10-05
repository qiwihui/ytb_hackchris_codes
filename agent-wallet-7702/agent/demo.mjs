// 端到端演示：在本地 anvil 上，用一笔真实的 EIP-7702（type 4）交易把 Alice 的 EOA 变成限额钱包，
// 再让一个「没有 ETH」的 AI agent 通过 relayer 代付 gas 去花钱，看限额怎么拦住它。
//
// 运行：先 `forge build`，再起 anvil，然后 `node demo.mjs`（或直接 ../run_demo.sh）
import { readFileSync } from "node:fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  formatUnits,
  parseUnits,
  parseEther,
  BaseError,
  ContractFunctionRevertedError,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { anvil } from "viem/chains";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const art = (name) => JSON.parse(readFileSync(new URL(`../out/${name}.sol/${name}.json`, import.meta.url)));
const Wallet = art("AgentWallet7702");
const Usdc = art("MockUSDC");

// anvil 默认账户
const deployer = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const relayer = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
// agent 用一把全新的 key，余额为 0，证明它不需要持有 gas
const agent = privateKeyToAccount(generatePrivateKey());
const merchant = privateKeyToAccount(generatePrivateKey()).address;

const pub = createPublicClient({ chain: anvil, transport: http(RPC) });
const client = (account) => createWalletClient({ account, chain: anvil, transport: http(RPC) });

const usdc6 = (x) => parseUnits(String(x), 6);
const fmt = (x) => `${formatUnits(x, 6)} USDC`;
const log = (...a) => console.log(...a);
const step = (t) => log(`\n━━ ${t} ━━`);

async function deploy(artifact, account) {
  const hash = await client(account).deployContract({ abi: artifact.abi, bytecode: artifact.bytecode.object });
  const r = await pub.waitForTransactionReceipt({ hash });
  return r.contractAddress;
}

function revertName(err) {
  if (err instanceof BaseError) {
    const r = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (r) return `${r.data?.errorName}(${(r.data?.args ?? []).map(String).join(", ")})`;
  }
  return err.shortMessage ?? String(err);
}

// agent 侧：按 EIP-712 签一笔 Execute，交给 relayer
async function agentSign(wallet, calls) {
  const nonce = await pub.readContract({ address: wallet, abi: Wallet.abi, functionName: "nonceOf", args: [agent.address] });
  // deadline 用链上时间，而不是本机时钟（演示里会快进区块时间）
  const deadline = (await pub.getBlock()).timestamp + 600n;
  const signature = await agent.signTypedData({
    domain: { name: "AgentWallet7702", version: "1", chainId: anvil.id, verifyingContract: wallet },
    types: {
      Call: [
        { name: "target", type: "address" },
        { name: "value", type: "uint256" },
        { name: "data", type: "bytes" },
      ],
      Execute: [
        { name: "sessionKey", type: "address" },
        { name: "calls", type: "Call[]" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Execute",
    message: { sessionKey: agent.address, calls, nonce, deadline },
  });
  return { nonce, deadline, signature };
}

// relayer 侧：拿到签名后代发（gas 由 relayer 付）
async function relay(wallet, calls) {
  const { nonce, deadline, signature } = await agentSign(wallet, calls);
  const hash = await client(relayer).writeContract({
    address: wallet,
    abi: Wallet.abi,
    functionName: "executeWithSession",
    args: [agent.address, calls, nonce, deadline, signature],
  });
  return pub.waitForTransactionReceipt({ hash });
}

const pay = (token, to, amount) => [
  { target: token, value: 0n, data: encodeFunctionData({ abi: Usdc.abi, functionName: "transfer", args: [to, amount] }) },
];

async function tryRelay(label, wallet, calls) {
  try {
    const r = await relay(wallet, calls);
    log(`  ✅ ${label} — 成功，gas ${r.gasUsed}（relayer 付）`);
  } catch (e) {
    log(`  ⛔ ${label} — 被拦下：${revertName(e)}`);
  }
}

async function main() {
  step("0. 部署：钱包实现合约 + 测试用 USDC");
  const impl = await deploy(Wallet, deployer);
  const usdc = await deploy(Usdc, deployer);
  await pub.waitForTransactionReceipt({
    hash: await client(deployer).writeContract({ address: usdc, abi: Usdc.abi, functionName: "mint", args: [alice.address, usdc6(1000)] }),
  });
  log(`  实现合约 ${impl}`);
  log(`  USDC     ${usdc}`);
  log(`  Alice    ${alice.address}，USDC 余额 ${fmt(await pub.readContract({ address: usdc, abi: Usdc.abi, functionName: "balanceOf", args: [alice.address] }))}`);
  log(`  Agent    ${agent.address}，ETH 余额 ${await pub.getBalance({ address: agent.address })}`);

  step("1. Alice 发一笔 type-4 交易：同一笔里完成 7702 委托 + 给 agent 开 session");
  log(`  委托前 Alice 的 code：${(await pub.getCode({ address: alice.address })) ?? "0x（普通 EOA）"}`);
  // executor: 'self' —— 授权签名者自己发这笔交易，nonce 要 +1，viem 会处理
  const authorization = await client(alice).signAuthorization({ contractAddress: impl, executor: "self" });
  const now = BigInt((await pub.getBlock()).timestamp);
  const cfg = {
    validAfter: Number(now),
    validUntil: Number(now + 7n * 86400n),
    permissions: [{ target: usdc, selector: "0xa9059cbb" }], // 只允许 USDC.transfer
    limits: [{ token: usdc, limit: usdc6(100), period: 86400 }], // 每天 100 USDC
  };
  const grantHash = await client(alice).writeContract({
    address: alice.address, // 发给自己：msg.sender == address(this)
    abi: Wallet.abi,
    functionName: "grantSession",
    args: [agent.address, cfg],
    authorizationList: [authorization],
  });
  const grantRcpt = await pub.waitForTransactionReceipt({ hash: grantHash });
  const tx = await pub.getTransaction({ hash: grantHash });
  log(`  交易类型 ${tx.type}，authorizationList 长度 ${tx.authorizationList?.length}，gas ${grantRcpt.gasUsed}`);
  log(`  委托后 Alice 的 code：${await pub.getCode({ address: alice.address })}`);
  log(`  （0xef0100 + 实现合约地址 —— 这就是 7702 的 delegation designator）`);
  const remaining = () => pub.readContract({ address: alice.address, abi: Wallet.abi, functionName: "remaining", args: [agent.address, usdc] });
  log(`  agent 今日剩余额度：${fmt(await remaining())}`);

  step("2. agent 付款：签 EIP-712，relayer 代发");
  await tryRelay("付 30 USDC 给商家", alice.address, pay(usdc, merchant, usdc6(30)));
  await tryRelay("付 50 USDC 给商家", alice.address, pay(usdc, merchant, usdc6(50)));
  log(`  剩余额度：${fmt(await remaining())}`);
  await tryRelay("再付 40 USDC（超额）", alice.address, pay(usdc, merchant, usdc6(40)));

  step("3. agent 被诱导（比如 prompt injection）想做越权的事");
  await tryRelay("approve 给攻击者无限额度", alice.address, [
    { target: usdc, value: 0n, data: encodeFunctionData({ abi: Usdc.abi, functionName: "approve", args: [relayer.address, 2n ** 256n - 1n] }) },
  ]);
  await tryRelay("调用钱包自己的 grantSession 给自己提额", alice.address, [
    {
      target: alice.address,
      value: 0n,
      data: encodeFunctionData({ abi: Wallet.abi, functionName: "grantSession", args: [agent.address, { ...cfg, limits: [{ token: usdc, limit: usdc6(1_000_000), period: 0 }] }] }),
    },
  ]);
  await tryRelay("把 Alice 的 ETH 转走", alice.address, [{ target: relayer.address, value: parseEther("1"), data: "0x" }]);

  step("4. 第二天额度重置");
  await pub.request({ method: "evm_increaseTime", params: [86400] });
  await pub.request({ method: "evm_mine", params: [] });
  log(`  剩余额度：${fmt(await remaining())}`);
  await tryRelay("付 40 USDC", alice.address, pay(usdc, merchant, usdc6(40)));

  step("5. Alice 一键撤销");
  await pub.waitForTransactionReceipt({
    hash: await client(alice).writeContract({ address: alice.address, abi: Wallet.abi, functionName: "revokeSession", args: [agent.address] }),
  });
  await tryRelay("撤销后再付 1 USDC", alice.address, pay(usdc, merchant, usdc6(1)));

  step("结果");
  const bal = (a) => pub.readContract({ address: usdc, abi: Usdc.abi, functionName: "balanceOf", args: [a] });
  log(`  商家收到 ${fmt(await bal(merchant))}（预期 120 = 30 + 50 + 40）`);
  log(`  Alice 剩余 ${fmt(await bal(alice.address))}`);
  log(`  agent 的 ETH 余额始终是 ${await pub.getBalance({ address: agent.address })}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
