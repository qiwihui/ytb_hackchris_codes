# 从零实现 EIP-7702 钱包

第 5 期配套教学代码：原地址上的批量执行、手续费代付、会话密钥及撤销。
使用 Solidity + Foundry + Python。没有 ERC-4337 实现；7702 本身也可与 4337 组合。

**教学实现，未经审计。只用本地测试资产。** 当前采用个人消息签名，绑定账户、链和应用 nonce，不是标准 EIP-712。会话没有金额、收款人或 selector 限制；目标为零允许任意外部目标，禁止自调用。通用低级 call 不检查代币返回 false。升级迁移和签名版本隔离需另外设计。

## 一次命令复现视频

```bash
git submodule update --init --recursive
python3.12 -m venv .venv
. .venv/bin/activate
pip install -r relayer/requirements.txt
forge build
forge test --offline -vv
python demos/record_demo.py --output evidence
```

最后一条命令启动独立的 `127.0.0.1:18545` Anvil / Prague，结束时关闭。
不读取 .env 私钥，不连接公链；使用公开测试钥匙（整数 1–4），绝不能向它们转入真实资产。
若端口被占用则拒绝继续，不复用或重置已有节点。

macOS 沙盒内 Foundry 若在系统代理读取时崩溃，可离线运行：

```bash
HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
ALL_PROXY=http://127.0.0.1:9 forge test --offline -vv
```

本期验收：16 项 Forge 测试通过；本地真实 type-4 委托、批量、代付、会话撤销、协议撤销均通过。回执、余额和 nonce 见生成的 `evidence/demo.json`。每次运行哈希可能不同。

## 目录结构

| 文件 | 作用 |
|---|---|
| src/account-7702/BatchExecutor.sol | 最小 self-only 批量入口 |
| src/account-7702/EOADelegate.sol | 执行、应用 nonce、签名与会话 |
| relayer/auth_tx.py | 协议授权和 type-4 提交 |
| relayer/auth_tx_cli.py | 手动 delegate / revoke |
| relayer/relayer.py | 主钥匙签名和代付 CLI |
| relayer/session_relay.py | 会话签名和代付 CLI |
| demos/record_demo.py | 视频使用的完整独立取证流程 |
| test/ | 权限、回滚、重放及撤销测试 |

## 调用流程

1. 用户签 7702 授权，代付方提交 type-4，将用户账户指向已部署代码。
2. 批量：用户向自己发交易，self-only 检查后循环执行。
3. 代付：用户签执行摘要，代付方向用户地址发送 executeWithSig。
4. 会话：用户添加临时钥匙，临时钥匙签名，executeBySession 验权后执行。
5. 移除会话后新请求被拒；协议委托到零地址后代码为空，存储仍保留。

## 关键设计

- execute / executeBatch：self-only，代码在用户账户上下文执行。
- _exec：对外调用失败继续抛错，实现批内回滚；不保证所有代币返回值为真。
- _store：ERC-7201 公式槽位；测试向公式位置写入并读取实际合约验证。
- executeWithSig：个人消息前缀 + target/value/data/nonce/chainId/account 摘要。
- executeBySession：恢复 signer、查会话表、检查时间和目标、禁止自调用；摘要绑定账户。
- addSessionKey / removeSessionKey：递增共享应用 nonce，使所有待执行签名失效。变更一把钥匙也影响其他 pending 请求，这是保守的教学取舍。

视频源码包的 code-references.json 与 production-source-manifest.json 保存精确行号和哈希。发布前再固定 commit 和远程链接；当前不伪造 GitHub URL。

vm.etch 仅测试执行逻辑；record_demo.py 使用真实 type-4 测协议路径。授权处理成功后，后续执行失败不会回滚委托标记。撤销清空代码，不清存储；普通空代码调用不一定 revert。

## 单步调试与背景材料

`demos/01..05` 是需要自行配置 .env 的手动流程；视频复现优先使用独立取证脚本。部署后设置 USER_ADDR、USDC、BATCHER、DELEGATE、SESSION_PK。会话管理是单独的用户付费交易，不属于零 ETH 转账演示。

`docs`、`deep-dive` 是背景阅读。实际签名、安全边界和验证结果以本 README、代码及测试为准。

## License

MIT。库依赖遵循各自许可证。
