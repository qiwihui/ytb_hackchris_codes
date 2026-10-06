# 02. EIP-7702 速查表

## SET_CODE_TX_TYPE = 0x04

Pectra 引入的新交易类型。在 EIP-1559 的类型 2 tx 之上，**只多一个字段**：`authorizationList`。

```
TransactionPayload = rlp([
    chain_id,
    nonce,
    max_priority_fee_per_gas,
    max_fee_per_gas,
    gas_limit,
    destination,
    value,
    data,
    access_list,
    authorization_list,        // <-- 新字段
    signature_y_parity, r, s
])
```

`authorization_list` 是若干个授权元组的列表：

```
authorization = (chain_id, address, nonce, y_parity, r, s)
```

- `chain_id` —— `0` 表示"任意链可用"；非零钉死到目标链。
- `address` —— 委托合约地址。**`0x000…000` 表示撤销**。
- `nonce` —— **授权 EOA 在该授权被执行的瞬间的 tx nonce**。
- 签名是对这个 magic 前缀的签名：
  `keccak256(0x05 || rlp([chain_id, address, nonce]))`。

### 上链后发生什么

对每条授权，EVM 做：

1. 从签名恢复出 EOA 地址。
2. 检查 `tx.nonce` 与之匹配。
3. 把 EOA 的 `code` 写成 `0xef0100 || address`（23 字节）。
4. EOA 的 nonce 加 1。

3 字节前缀 `0xef0100` 是不可执行标记（EIP-3541 保留了 `0xef`）。
之后任何 `CALL` 到该 EOA 的交易，EVM 会透明地跟随委托指针，执行委托合约的运行时代码，**但 `address(this) == EOA`，且使用 EOA 自身的存储命名空间**。

## 三种签名者 / 发送者组合

| 外层 tx 签名者 | 授权签名者 | 用途 |
|----------------|------------|------|
| EOA | EOA | 自我委托。EOA 自付 gas。 |
| EOA-A | EOA-B | A 委托 B 用 A 的 code？不对——两者签的必须是同一个 EOA。 |
| Sponsor | EOA | 代付方付 gas，给 EOA 装代码。 |

最后一行是真正的解锁：**用户无需持有 ETH 就能变成智能账户**。

## 三个会咬人的坑

1. **`nonce` 是 EOA 的 tx nonce。** 如果 EOA 自己发这笔类型 4 tx，外层 tx 和授权共享这个 nonce，并且执行时 EOA nonce 加 1——但你写到授权签名里的 `nonce` 应该是 `current + 1`（因为外层 tx body 先消费了 `current`）。差一就被静默丢弃。
2. **`chain_id = 0` 是地雷。** 跨链 replay 风险——本 repo 永远钉死目标链。详见 `deep-dive/replay-protection.md`。
3. **撤销不清存储。** 把委托撤销只清掉 EOA 的 *code*，不清 *storage*。后续再委托到一个用同样 EIP-7201 slot 的 v2 合约，你就继承了 v1 的状态。bump 命名空间字符串可避免。

## 我们在 repo 里怎么签

`relayer/auth_tx.py::sign_authorization` 调 `eth_account.Account.sign_authorization`，它会替你处理 `0x05` magic 前缀（`eth-account >= 0.13`）。
