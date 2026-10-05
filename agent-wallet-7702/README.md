# 给 AI agent 一个钱包：用 EIP-7702 + session key 做限额授权

把 [x402](https://www.x402.org/) 和 4337/7702 两条线串起来：
让 AI agent 能自己付钱，但只能在你划好的圈里花。

- 合约：`src/AgentWallet7702.sol`（约 300 行，无外部依赖除 OZ 的 ECDSA）
- 测试：`test/AgentWallet7702.t.sol`（29 个用例，含 512 轮模糊测试，全部通过）
- 端到端演示：`agent/demo.mjs`（本地 anvil 上发真实的 type-4 交易，agent 用 viem）

> 本项目是教学实现，未经审计，不要直接用于主网资产。生产环境可以优先看成熟方案
>（例如模块化智能账户的 session key 模块、各大钱包的 spend permission 方案），再对照本文的检查清单评估。

## 0. 一句话

用户的普通钱包（EOA）用一笔 EIP-7702 交易「挂上」一段合约代码，变成智能钱包；
然后给 AI agent 发一把 **session key**：只能调指定合约的指定函数、每天最多花多少、到期自动失效、主人随时一键撤销。
agent 甚至不用持有 ETH，签个名交给 relayer（比如 x402 的 facilitator）代发就行。

## 1. 为什么 agent 不能直接拿私钥

| 方案 | 问题 |
| --- | --- |
| 把主钱包私钥给 agent | 全权。一次 prompt injection、一个有 bug 的工具，钱包就空了 |
| 给 agent 单独开一个钱包，往里充钱 | 能控上限，但要来回充值；资产分散；没法限制「只能付给谁、只能调哪个函数」 |
| 4337 智能账户 + session key | 能做，但用户要换新地址、迁移资产 |
| **7702 + session key（本项目）** | 地址不变，资产不动，规则写在链上，agent 的 key 泄露也只损失当天额度 |

## 2. EIP-7702 是怎么工作的

Pectra 升级（2025-05 主网）引入了新交易类型 **type 4**，多了一个 `authorizationList`。每条授权是：

```
(chain_id, address, nonce, y_parity, r, s)   // 由 EOA 私钥签名
```

节点处理这笔交易时，会在执行前把签名者 EOA 的 code 设成一个 23 字节的 **delegation designator**：

```
0xef0100 || address
```

之后任何人调用这个 EOA，EVM 都会去执行 `address` 那份合约的代码，但：

- **执行上下文是 EOA 自己**：`address(this)` 是用户地址，`msg.sender` 是调用方；
- **存储写在 EOA 自己的 storage 里**，而不是实现合约里；
- **EOA 私钥仍然有效**，主人仍可以直接发交易，也可以随时重新委托或委托给 `address(0)` 来清除。

演示里实际看到的：

```
委托前 Alice 的 code：0x（普通 EOA）
交易类型 eip7702，authorizationList 长度 1
委托后 Alice 的 code：0xef01005fbdb2315678afecb367f032d93f642f64180aa3
```

一个关键技巧：**授权在交易执行前生效**，所以「委托 + 开 session」可以在同一笔交易里完成——
Alice 给自己发一笔 type-4 交易，`to` 是自己的地址，calldata 是 `grantSession(...)`。

## 3. 合约设计

### 3.1 三种调用者

```
            ┌───────────────── 用户 EOA（代码 = AgentWallet7702）────────────────┐
 Alice ───▶ │ execute / grantSession / revokeSession      （onlySelf：msg.sender == address(this)）
 agent ───▶ │ executeAsSession                             （msg.sender == session key，agent 自付 gas）
 relayer ─▶ │ executeWithSession(key, calls, nonce, deadline, sig)   （agent 只签名，relayer 付 gas）
            └───────────────────────────────────────────────────────────────────┘
```

### 3.2 「谁是主人」不需要初始化

```solidity
modifier onlySelf() {
    if (msg.sender != address(this)) revert OnlySelf();
    _;
}
```

主人就是这个地址本身：Alice 给自己发交易时 `msg.sender == address(this)`。
**没有 `initialize()`，也就没有「委托之后、初始化之前」被别人抢先调用的窗口**。
7702 上线后已经出现过 delegate 合约留着未初始化的 owner、被攻击者先一步初始化的事故，这是最值得避开的坑。

### 3.3 存储用 ERC-7201 命名空间

代码跑在用户 EOA 上，存储也落在 EOA。用户以后可能换别的 delegate 合约，
如果大家都从 slot 0 开始写，旧数据会被新合约误读。所以所有状态放在一个命名空间结构里：

```solidity
/// @custom:storage-location erc7201:hackchris.agentwallet.v1
struct Layout { sessions; allowed; allowances; nonces; }
bytes32 constant LAYOUT_SLOT = keccak256(abi.encode(uint256(keccak256("hackchris.agentwallet.v1")) - 1)) & ~0xff;
```

### 3.4 session 的规则

```solidity
struct SessionConfig {
    uint48 validAfter;            // 生效时间
    uint48 validUntil;            // 过期时间
    Permission[] permissions;     // (合约, 函数选择器) 白名单；selector=0 表示纯 ETH 转账
    TokenLimit[] limits;          // 每种资产的额度和周期；token=0 表示 ETH；period=0 表示终身额度
}
```

执行每一个 call 之前，`_enforce` 按顺序检查：

1. **禁止调用钱包自己**：否则 agent 可以调 `grantSession` 给自己提额。授权时也会拒绝指向自身的权限（双保险）。
2. **(合约, 函数) 白名单，默认拒绝**。
3. **ETH**：`call.value` 计入 ETH 额度；没配 ETH 额度就不能转 ETH。
4. **ERC20**：对 `transfer` / `approve`，从 calldata 里解出金额计入该 token 的额度。
   - `approve` 也算花钱：授权本身就是「花钱的权力」，否则 `approve(attacker, max)` 一步绕过所有限额；
   - 被限额的 token 只允许这两个函数，`transferFrom`、`permit`、`increaseAllowance` 之类一律拒绝；
   - 没配额度的 token 一律拒绝（`NoLimitForAsset`）。
5. **周期额度**：过了 `period` 自动重置；同一笔批量交易里多个 call 累计计算。

检查和记账在外部调用之前完成（Checks-Effects-Interactions），整个入口还有一个基于
EIP-1153 transient storage 的重入锁，交易结束自动清零，不占永久存储。

### 3.5 重新授权会清空旧规则：epoch

Solidity 的 mapping 没法清空。如果重新授权时只是覆盖，上一次授权的白名单还残留在 storage 里。
做法是给每个 session 一个 `epoch`，所有权限和额度都按 `[key][epoch]` 存，重新授权时 `epoch + 1`，旧的整体失效。
测试 `test_regrantWipesOldPermissions` 专门覆盖这一点。

### 3.6 relayer 代发：EIP-712 签名

agent 签的结构：

```
Execute(address sessionKey, Call[] calls, uint256 nonce, uint256 deadline)
Call(address target, uint256 value, bytes data)
```

域（domain）里 `verifyingContract = address(this)`，也就是**用户的 EOA 地址**，再加上 `chainId`：

| 攻击 | 为什么失败 | 对应测试 |
| --- | --- | --- |
| relayer 重放同一个签名 | 每个 session key 有递增 nonce | `test_revert_replaySameSignature` |
| relayer 篡改收款人 | 签名覆盖了完整的 calls | `test_revert_tamperedCalls` |
| 拿 Alice 钱包的签名去 Bob 钱包用 | verifyingContract 不同 | `test_revert_crossWalletReplay` |
| 拿到另一条链上用 | chainId 不同 | `test_revert_crossChainReplay` |
| 囤着签名以后用 | deadline | `test_revert_expiredSignature` |
| 用别的 key 冒签 | 恢复出的地址必须等于 session key；OZ ECDSA 拒绝可延展签名 | `test_revert_signatureByWrongKey` |

## 4. 端到端演示（真实 type-4 交易）

```bash
git init && forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.4.0
./run_demo.sh          # 编译 → 起 anvil → 跑 agent/demo.mjs
```

实际输出（agent 的 key 每次随机生成，ETH 余额始终为 0）：

```
━━ 2. agent 付款：签 EIP-712，relayer 代发 ━━
  ✅ 付 30 USDC 给商家 — 成功，gas 124108（relayer 付）
  ✅ 付 50 USDC 给商家 — 成功，gas 72808（relayer 付）
  剩余额度：20 USDC
  ⛔ 再付 40 USDC（超额） — 被拦下：LimitExceeded(USDC, 40000000, 20000000)

━━ 3. agent 被诱导（比如 prompt injection）想做越权的事 ━━
  ⛔ approve 给攻击者无限额度 — 被拦下：CallNotAllowed(USDC, 0x095ea7b3)
  ⛔ 调用钱包自己的 grantSession 给自己提额 — 被拦下：SelfCallForbidden()
  ⛔ 把 Alice 的 ETH 转走 — 被拦下：CallNotAllowed(0x3C44…93BC, 0x00000000)

━━ 4. 第二天额度重置 ━━
  剩余额度：100 USDC
  ✅ 付 40 USDC — 成功

━━ 5. Alice 一键撤销 ━━
  ⛔ 撤销后再付 1 USDC — 被拦下：SessionInactive()

━━ 结果 ━━
  商家收到 120 USDC（预期 120 = 30 + 50 + 40）
```

完整输出见 `demo_output.txt`。

和 x402 的关系：x402 里服务端返回 402，客户端签名付款、facilitator 上链结算。
把本项目的 relayer 换成 facilitator，agent 每次付费请求就是一次 `executeWithSession`，额度由链上合约兜底。

## 5. 测试

```bash
forge test
```

29 个用例，分组：

- 7702 基本面：委托后 code 是 `0xef0100 || impl`
- 正常路径：relayer 代发、agent 直发、ETH 支付、批量累计
- 额度：超额、周期重置、终身额度不重置、approve 计入额度、未配额度的 token
- 白名单：目标不在名单、函数不在名单、调用钱包自身、授权指向自身
- 时间：过期、未生效、撤销立即生效、重新授权清空旧规则
- 权限边界：只有主人能授权 / 撤销、主人不受限、未知 key
- 签名：重放、错 key、篡改、过期、跨钱包、跨链
- 模糊测试：同一周期内任意拆单，总支出 ≤ 额度（512 轮）

## 6. 这个设计**没有**解决的问题

上线前一定要想清楚：

1. **白名单里放了 DEX router 之类的「万能」合约，限额就可能被绕过。** 本合约只对 `transfer` / `approve` 记账，
   router 能用你之前给它的 allowance 把币转走。只把你完全理解的函数加进白名单。
2. **额度按 token 的原始单位算，不是按美元。** 多币种要分别设额度。
3. **额度内的浪费拦不住。** agent 被骗着把今天 100 USDC 付给一个假商家，合约看来完全合法。收款方白名单要靠业务层，或者把收款地址也编码进规则。
4. **主人私钥泄露等于全部失守。** 7702 不会让 EOA 私钥失效。
5. **换 delegate 不会清 storage。** 用户以后委托给别的合约，本合约的数据还留在 EOA 里；命名空间只是避免冲突，不是删除。
6. **签授权要谨慎。** 7702 授权签了就等于把整个账户交给那份代码；`chain_id = 0` 的授权在所有链上都有效。钱包 UI 应该只允许委托给审计过的合约。
7. **`tx.origin == msg.sender` 不再代表「调用者是 EOA」。** 老合约里靠这个判断「不是合约」的逻辑，在 7702 之后失效。

## 7. 文件

```
src/AgentWallet7702.sol          合约
test/AgentWallet7702.t.sol       测试
test/mocks/MockUSDC.sol          测试用 6 位小数 ERC20
agent/demo.mjs                   viem 写的 agent + relayer 端到端演示
run_demo.sh                      一键演示
demo_output.txt                  演示实际输出
```
