# 从零复现 Liquid Network 3.2 亿美元的 range proof 缓存漏洞

> **声明**：这是一个**已公开、已修复**的 consensus bug 的教学复盘。主网（liquidv1）
> 早在 2026-09-09 就升级到 Elements v23.3.4，此漏洞在主网已不存在，被盗资金
> 也已退回约 85%。本复现全程在**本地隔离环境（regtest）**进行，不针对任何真实网络。
> 来源均为官方与第三方公开复盘（见文末）。

## 0. 一句话讲清楚

Liquid 为了省 CPU，把「range proof 验证通过」的结果缓存起来，下次遇到同样的 proof 直接判过。
但缓存的 key 是把几个**变长字段裸拼接**后做 SHA256，**没有长度分隔符**。
攻击者把字段边界一平移，就能让一笔**非法输出**和一笔**合法输出**算出**同一个缓存 key**——
合法那笔先把 key 写进缓存，非法那笔直接命中，于是**从没被真正验证过的 proof 被判为有效**，
凭空铸出约 4000 L-BTC，再通过 peg-out 提走约 3996 BTC。

这是个教科书级的 **length-extension / 字段边界歧义** 问题，跟很多 Solidity 里
`abi.encodePacked` 拼接后再 hash 导致的碰撞，是**同一类错误**。

## 1. 背景：Confidential Transactions 与 range proof

Liquid 是比特币侧链，用 **Confidential Transactions（CT）** 把金额和资产类型藏起来：

- **value commitment** `C = v·H + r·G`：Pedersen 承诺，把金额 `v` 藏在里面。
- **asset commitment** `A`：把「这是哪种资产」藏起来。
- 既然金额是藏着的，怎么保证没人凭空造钱？靠 **range proof**：
  用 Bulletproofs/borromean 证明「被藏起来的金额落在 `[0, 2^64)` 内、没有溢出造假」，
  而**不泄露**具体数值。
- **surjection proof**：证明「输出资产确实来自某个输入资产集合」，防止凭空造资产。

验证 range proof 很贵（椭圆曲线运算）。同一个 proof 在内存池和入块时会被验证多次，
所以 Elements 加了个 **range proof 验证缓存**：验证通过就把结果缓存，下次命中直接返回 true。
问题全部出在这个缓存的 **key 怎么算**。

## 2. 漏洞根因：两个叠加的 bug

### Bug A（2018-04 引入，2026-08 才修）

最初缓存 key 只用了 `proof || value_commitment` 两个字段，
**漏掉了 asset_commitment 和 scriptPubKey**。而 range proof 的有效性其实是**绑定**
asset commitment 和 scriptPubKey 的。key 里不带它们，就可能出现
「换了 asset/脚本，却命中旧缓存」的 consensus split 风险。

研究者 stutxo 在 2026-08-02 报告了 Bug A。Blockstream 2026-08-03 用 commit
`212c43f47`「fix: range proof cache bind to asset and scriptpubkey」把这两个字段
**补进了 key**：

```cpp
// src/script/sigcache.cpp —— Bug A 的修法
void ComputeEntryRangeProof(uint256& entry,
        const std::vector<unsigned char>& proof,
        const std::vector<unsigned char>& commitment,
        const std::vector<unsigned char>& asset_commitment,  // 新增
        const CScript& scriptPubKey) {                        // 新增
    CSHA256 hasher = m_salted_hasher_range_proof;
    hasher.Write(proof.data(), proof.size())
          .Write(commitment.data(), commitment.size())
          .Write(asset_commitment.data(), asset_commitment.size())  // ← 裸拼
          .Write(scriptPubKey.data(), scriptPubKey.size())          // ← 裸拼
          .Finalize(entry.begin());
}
```

### Bug B（Bug A 的修法本身引入，2026-09-06 被利用）

Bug A 的修法把四个字段 `proof || commitment || asset_commitment || scriptPubKey`
**直接按字节拼起来**喂进 SHA256，**没有任何长度前缀**。这就制造了字段边界歧义：

> 由于 proof 和 scriptPubKey 都是变长的，攻击者可以把 proof 截短 / 拉长，
> 再相应地调整 scriptPubKey 来补偿，让两组**不同**的 `(P, C, A, S)` 拼出
> **完全相同**的字节流，从而命中同一缓存 key。

时间线特别关键：Bug A 的修复 PR 在 **2026-09-01 公开 merge**，Bug B 的代码随之暴露；
**2026-09-06** 就被利用。从「补丁公开」到「被打」只隔了 5 天——这本身就是
「补丁即攻击说明书」的典型案例。

## 3. 攻击怎么构造碰撞（本复现的核心）

四个字段在裸拼接下变成一条字节流。攻击者把「字段边界」整体平移：

| | proof (P) | value_c (C) | asset_c (A) | scriptPubKey (S) |
| --- | --- | --- | --- | --- |
| **合法 setup 输出** | `P0` | `C0` | `X` | `6a43‖C1‖X‖6a` |
| **非法铸造输出** | `P0‖C0‖X‖6a43` | `C1` | `X` | `6a` |

两行裸拼接后都等于：`P0 ‖ C0 ‖ X ‖ 6a43 ‖ C1 ‖ X ‖ 6a`，**一模一样**。
（`6a` = `OP_RETURN`，`6a43` = `OP_RETURN` + push 0x43=67 字节；
攻击者把本该在 proof 里的字节「藏」进 scriptPubKey，或反过来。）

于是：

1. 合法 setup 输出的 range proof 是**真·有效**的，被真正验证通过，缓存 key 写入。
2. 非法铸造输出的 range proof 其实是**垃圾**（根本证明不了金额合法），
   但它的缓存 key 和第 1 步**撞上了**，`rangeProofCache.Get(entry)` 直接命中返回 true，
   **VerifyRangeProof 从未对它做真正的密码学验证**。
3. 非法输出因此被共识接受，攻击者给自己铸出约 4000 L-BTC 的凭空金额。

**运行 `collision_demo.py` 就能在本地秒级看到这个碰撞**（不需要编译整个节点）：

```shell
$ python3 collision_demo.py
...
[4] 漏洞版 cache key（裸拼接）:
    合法 key = e3f976d009...539ed1
    非法 key = e3f976d009...539ed1
    >>> 碰撞？ True  ← 非法输出命中合法缓存，直接被判 valid！
[5] 补丁版 cache key（CHashWriter 长度前缀）:
    >>> 碰撞？ False  ← 不再碰撞，非法输出会走真实验证并被拒绝。
结论：漏洞版碰撞成立、补丁版碰撞消失 —— 复现成功 ✅
```

这个脚本是全片最硬的「证据」：它一字不差地复刻了 `sigcache.cpp` 里两个版本的
key 计算函数，直接证明「漏洞版会撞、补丁版不会」。

## 4. 补丁：长度前缀化

2026-09-08 commit `94000967f`「sigcache: harden proof cache keys with
length-prefixed hashing」把裸拼接的 `CSHA256` 换成 `CHashWriter(SER_GETHASH)`。
Elements 的 `<<` 序列化会给每个变长字段**自动加 CompactSize 长度前缀**，
字段边界从此不可伪造：

```cpp
// 补丁后
void ComputeEntryRangeProof(uint256& entry, ...) const {
    CHashWriter hasher = m_salted_hasher_range_proof;   // SER_GETHASH
    hasher << proof << commitment << asset_commitment << script_pub_key;
    entry = hasher.GetSHA256();
}
```

同一个 PR 还：

- 给 surjection proof 的 key **补上了之前完全漏掉的 `vTags`**（同类问题）；
- 新增启动参数 `-norangeproofcache` 让节点能**完全关掉**这个缓存（应急开关）；
- 加了一组碰撞测试 `src/test/sigcache_tests.cpp`。

正式修复版本 **Elements v23.3.4** 于 2026-09-09 发布，经 Bitcoin Red Team 与
Alpen Labs 审查。

还有一个工程教训值得点出：补丁在 `VerifyRangeProof` 上方留了行注释——
**「本函数每一个携带数据的参数都必须进入 ComputeEntryRangeProof，漏掉任何一个
都可能让不同输入命中同一缓存」**。这正是从这次事故里提炼出的、防止重蹈覆辙的规约。

## 5. 攻击 → 提现全链路（讲「为什么能提走真 BTC」）

凭空铸币只是第一步，钱能提走还要过 peg-out：

| 时间 (UTC) | 事件 |
| --- | --- |
| 09-06 13:52:10 | setup 交易 `271147100a94...`（写入合法缓存 key） |
| 09-06 13:53:10 | 铸币交易 `f24a4b179b5c...`（命中缓存，凭空铸 ~4000 L-BTC），Liquid 块 4,050,336 |
| 09-06 14:01–14:06 | 通过 SideSwap peg-out 提走 ~3998.5 L-BTC → BTC |
| 09-06 14:28:56 | ~3996 BTC 落到比特币主网单地址，比特币块 965,783 |
| 09-06 18:26 | bridge node 停机，网络暂停 |
| 09-07 16:09 | 攻击者退回 3400 BTC（比特币块 965,950），自称白帽 |
| 09-09 21:05 | 升级 v23.3.4 后恢复出块 |

**为什么能瞬间提走**：Liquid 的 peg-out 用 **PAK（Peg-out Authorization Key）**
机制，联邦 11/15 多签。按《Federation Charter》签名用的 online key 不该长期在线、
提现也该有人工/限速审核。但 SideSwap 承认当时：签名 key 在线、提现**在同一个
比特币块里自动转发给用户**、没有速率控制或人工复核。共识层把伪造交易当成合法，
多签就照签不误。**一个加密 bug + 一个运维失误，合起来才酿成 3.2 亿**。

## 6. 复现环境：本地 regtest 跑真节点（进阶章节）

`collision_demo.py` 已经独立证明了 key 碰撞。如果还想展示「在真·Elements
节点上让非法交易被接受」，用**本地 regtest**，不碰任何真实网络：

```bash
# 1) 拉源码
git clone https://github.com/ElementsProject/elements.git
cd elements

# 2) 还原到「含 Bug A 修法、但还没上长度前缀补丁」的状态
#    （即 212c43f47 之后、94000967f 之前）
git checkout 212c43f47          # 或在此基础上 cherry-pick 到当时 liquidv1 的提交点

# 3) 编译（Ubuntu 示例，约 10-20 分钟）
./autogen.sh
./configure --disable-bench --disable-tests --without-gui
make -j$(nproc)

# 4) 起一个隔离的 regtest 链
cat > /tmp/elements-vuln/elements.conf <<'EOF'
chain=elementsregtest
elementsregtest=1
[elementsregtest]
server=1
rpcuser=user
rpcpassword=pass
validatepegin=0
initialfreecoins=2100000000000000
con_dyna_deploy_signal=1
EOF
src/elementsd -datadir=/tmp/elements-vuln -daemon
```

然后用一个 Python 脚手架（建议基于 `python-bitcointx` / `rust-elements` 的 PSET
构造）生成第 3 节表格里那对「可碰撞输出」，先广播合法 setup 交易把缓存 key 写进去，
再广播非法铸币交易，观察漏洞节点**接受**了它、`getwalletinfo` 里凭空多出 L-BTC；
再把节点换成 v23.3.4 或加 `-norangeproofcache`，同一笔交易被**拒绝**。

## 7. 来源

- Blockstream 官方复盘：<https://blog.blockstream.com/liquid-network-security-incident-assessment/>
- CertiK 分析：<https://www.certik.com/blog/liquid-network-incident-analysis>
- TRM Labs：<https://www.trmlabs.com/resources/blog/2026s-biggest-hack-to-date-attackers-drained-usd-319-million-in-bitcoin-from-liquid-network-then-returned-85-of-funds>
- Elements 源码与补丁：<https://github.com/ElementsProject/elements> （commit `212c43f47`、`94000967f`；tag `elements-23.3.4`）
- v23.3.4 发布说明（KuCoin 转载）：<https://www.kucoin.com/news/flash/liquid-network-releases-elements-v23-3-4-emergency-update-to-fix-proof-verification-cache-vulnerability>
