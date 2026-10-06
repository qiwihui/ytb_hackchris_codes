# 7702 委托里的重放保护

三层防护，各自挡一个攻击：

| 层 | 在哪里 | 挡什么 |
|----|--------|--------|
| 7702 授权元组里的 `chain_id` | EVM 层 | 跨链委托重放 |
| 个人消息（非 EIP-712） `Execute` typehash 里的 `chainId` | 委托代码 | 跨链 `executeWithSig` 重放 |
| `MainStorage` 里单调递增的 `nonce` | 委托代码 | 同链 `executeWithSig` 重放 |

## 为什么不直接用 EOA 的 tx nonce？

`executeWithSig` 是代付的——**链上推进的是 relayer 的 tx nonce**。EOA 的 tx nonce 只有在 EOA 自己广播时才动。所以一笔由 relayer 提交的调用必须自己维护一个计数器，这个计数器活在委托的存储里。

## `chainId = 0` 这个地雷

7702 规范允许在授权元组里把 `chain_id` 写成 0，意思是"任意链可用"。方便（一笔签名就能让所有 EVM 链都开委托），但危险：如果同一个 EOA 在另一条你压根没打算授权的链上也存在，攻击者可以把这条授权直接 replay 过去。

本 repo **永远把 `chain_id` 钉死到目标链**。如果真的想跨链委托，那应该是一个**独立的**签名对象，而不是"少签了一个字段"。

## 我们刻意没修的一个角落

如果 EOA 委托到 V1，签了 `n` 笔代付请求（nonce `0..n-1`），而 relayer **全部丢了**，那么 EOA 看到的"下一个有效 nonce"和链上实际状态会发散。恢复路径：EOA 自己直接调用一次 `execute`（不动代付 nonce 计数器），再读 `nonce()` 校准。

生产级钱包会做"gap recovery"——EOA 通过签一笔自调用强行让计数器跳过卡住的 nonce。我们没做，视频里把它点成"你 fork 这个 repo 后第一个该补的功能"。
