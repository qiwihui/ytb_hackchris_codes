# 7702 下的存储冲突

## 背景

委托之后，EOA 的**存储**仍是自己的——每次 `SLOAD/SSTORE` 都落在以 EOA 地址为前缀的槽里。它**运行**的代码是委托合约的。所以如果用户 U 装了委托 V1、写了 V1 的存储布局，再换装 V2 但 V2 的存储布局不同，V2 会把 V1 写过的字节当成自己的字段来读。

这不是理论问题。这是 2017–2019 撞坏代理合约的同一类 bug（Parity 多签）。修法也是同一套：**确定性、抗冲突的槽位推导**（EIP-1967 / EIP-7201）。

## 为什么用 EIP-7201（不是 EIP-1967）

EIP-1967 覆盖代理的"实现地址"槽。EIP-7201 覆盖合约想命名空间隔离的**任意 struct**。我们有一个 struct（`MainStorage`），包含 `nonce` 和 `sessionKeys` 映射——这正是 EIP-7201 的标准用法。

槽位公式：

```
slot = keccak256(abi.encode(uint256(keccak256("eoadelegate.main")) - 1))
       & ~bytes32(uint256(0xff));
```

`-1` 与末字节清零是规范的两个细节：在 root 后面留 256 个槽做 scratch buffer，并让 root 本身不是某个明显字符串的 preimage。

## 一个具体的故障场景

假设 v1 把 `nonce` 放在 `slot 0`。用户 U 添加了 4 把会话密钥，发了 2 笔代付 tx（nonce → 2）。

用户升级到 v2。v2 把 `bool initialized` 放在 `slot 0`、`nonce` 放在 `slot 1`。

- v2 读 `slot 0` → `2` → cast 到 `bool` → `true` → "已初始化，跳过 setup"。
- v2 读 `slot 1` → `0` → 下一笔代付 tx **直接 replay v1 的签名**。

EIP-7201 让这一切不可能发生：v2 的存储 root 在另一个命名空间（`"eoadelegate.main.v2"`）。

## 这一招**不**解决什么

EIP-7201 不会把 v1 的数据迁移到 v2。如果 v2 的 struct 布局与 v1 不同，用户就**放弃**了 v1 的状态。对会话密钥存储而言无所谓（重发 key 即可）；但对"余额计数器"这种字段就不行。需要长期演进存储布局的生产级委托，必须实现一个显式的 v1 → v2 迁移函数（只能由 EOA 自己调用）。
