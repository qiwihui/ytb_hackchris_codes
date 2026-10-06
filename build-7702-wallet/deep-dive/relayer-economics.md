# Relayer 经济 —— 谁会替你付 gas，为什么

## 最朴素的版本

我们 `relayer/relayer.py` 就是一把有 ETH 的私钥，负责广播 `executeWithSig`。它**不**主动收报销。这套适合：

- **用户自己当 relayer**（拿第二把私钥做"广播热钱包"，把"签名冷设备"和"广播热钱包"拆开）。
- **产品自己当 relayer**（钱包厂商把 gas 摊到 CAC 里，在新用户 onboarding 期间吃下）。

它**不适合**开放的 relayer 市场。

## 三种真实的补偿模型

### 1. 稳定币 pull-payment（呼应 x402）

把 `executeWithSig` 实际上写成 `executeBatch([userAction, payRelayer])`，`payRelayer` = `USDC.transfer(relayer, gasCost * markup)`。用户对两条调用一起签，atomically 上链。userAction 失败 → 整条 batch revert → relayer 不付出无效 gas（不完全对，但白话理解）；userAction 成功 → relayer 在同一笔里被付掉。

用户付出的额外成本：一次 ERC-20 transfer 的 overhead。
relayer 承担的风险：打包窗口内的稳定币价格波动（L2 上几乎可忽略）。

### 2. Permit + transferFrom

用户签一笔 EIP-2612 `permit`，给 relayer 一次性 allowance；relayer 广播完用户的主调用之后，下一笔自己 pull 报销。两笔 tx，但用户主调用没有内联 overhead。

### 3. 链下结算（订阅制）

钱包 app 每月通过信用卡向用户收 $5；relayer 直接吃 gas。UX 最好，去中心化最差。生产级钱包大多走这条。

## 为什么 7702 让 relayer 市场真正可行

7702 之前，给 EOA 的 tx 代付**根本不可能**——EOA 必须自己签外层 tx 并自付 gas。4337 让它成为可能，但只能走 EntryPoint 流水线。**7702 让代付关系变成任何 EOA 的通用属性**——任何运行了带 `executeWithSig` 风格入口的委托的 EOA 都可被代付，不需要任何专用基础设施。

## 本 repo 刻意没有的部分

- 费率预言机（`USDC per gas` 报价）
- 多 relayer 拍卖（避免某个 relayer 单方面靠抬"手续费"来审查用户）
- relayer 信誉 / 质押

这些属于"relayer 网络"主题的 repo，不属于"教你写第一个 7702 钱包"的 repo。
