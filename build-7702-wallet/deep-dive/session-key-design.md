# 会话权限的实际边界

本实现使用个人消息签名，不是 EIP-712。Execute 与 SessionExecute 使用不同类型哈希区分操作域；主入口要求 signer 等于账户自身，会话入口查询权限表。不能声称仅靠类型哈希就解决全部提权问题。

摘要绑定 target/value/data/nonce/chainId/account，恢复出的 signer 用于查表。同一 key 在多个账户使用时，账户绑定阻止跨账户重放。

检查 flags、validAfter、validUntil、allowedTarget；禁止调用账户自身，避免进入 self-only 管理入口。allowedTarget=0 允许任意其他目标，并不是低权限的充分条件。

添加、替换、移除 key 均递增共享应用 nonce，使先前 pending 签名失效，避免同一 key 重授权后旧签名恢复有效。代价是所有会话及主钥匙的 pending 请求一起失效。独立 nonce lane / epoch 可作为后续扩展。

尚无金额、收款人、selector 和每日次数限制。当前测试不是审计。
