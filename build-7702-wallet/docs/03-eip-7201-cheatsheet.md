# 03. EIP-7201 速查表（命名空间存储）

为什么这对 7702 很关键：你将来可能往同一个 EOA 上装的每一个委托合约**共享**同一个存储命名空间——EOA 自己的存储。如果两个委托都往 `slot 0` 写东西，第二个委托会静默覆盖第一个的所有 bookkeeping。

这不是理论问题。这是 2017–2019 撞坏代理合约的同一类 bug（Parity 多签）。修法也是同一套：**确定性、抗冲突的槽位推导**（EIP-1967 / EIP-7201）。

## 为什么选 EIP-7201（而不是 EIP-1967）

EIP-1967 覆盖代理的"实现地址"槽。EIP-7201 覆盖合约想要命名空间隔离的**任意 struct**。我们有一个 struct（`MainStorage`），包含 `nonce` 和 `sessionKeys` 映射——这是 EIP-7201 的标准应用场景。

槽位公式：

```
slot = keccak256(abi.encode(uint256(keccak256("eoadelegate.main")) - 1))
       & ~bytes32(uint256(0xff));
```

`-1` 与末字节清零是规范的两个细节，意思是"在 root 后面留 256 个槽做 scratch buffer，并保证 root 本身不是某个明显字符串的 preimage"。

## Solidity 里的访问模式（≥ 0.8.x）

```solidity
struct MainStorage { uint256 nonce; mapping(address => SessionKey) sessionKeys; }

function _store() private pure returns (MainStorage storage $) {
    bytes32 slot = SLOT;
    assembly { $.slot := slot }
}
```

`forge inspect EOADelegate storageLayout` 能看到命名空间 root 和挂在它下面的字段。对比一下"直接用 `slot 0`"的委托，你立刻明白两个委托无法共用同一布局的根本原因。

## 我们怎么处理的

`EOADelegate.MAIN_STORAGE_SLOT` 用字面量硬编码——Solidity 0.8.27 还不支持嵌套 `keccak256` 在 `constant` 表达式里求值。测试 `test_StorageSlotMatchesFormula` 在运行时按公式重算并断言相等：一旦你改了命名空间字符串，这个测试会立刻红，提示你更新字面量。这是 OZ 同款做法。
