// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title AgentWallet7702
/// @notice 给 AI agent 用的限额钱包。用户的 EOA 通过 EIP-7702 把代码委托给本合约，
///         然后给 agent 的 session key 授权：能调哪些合约、哪些函数、每个周期最多花多少、什么时候过期。
///
///         三种调用者：
///         1. EOA 本人（msg.sender == address(this)）：管理 session、任意执行。
///         2. session key 直接发交易：executeAsSession。
///         3. 任意 relayer 代发：executeWithSession，带 session key 的 EIP-712 签名（agent 不需要持有 gas）。
///
/// @dev 7702 下合约代码跑在用户 EOA 的地址上，存储也写在 EOA 里。
///      所以存储用 ERC-7201 命名空间，避免以后换别的 delegate 时槽位冲突。
contract AgentWallet7702 {
    // ------------------------------------------------------------------
    // 类型
    // ------------------------------------------------------------------

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice 允许 session 调用的 (合约, 函数)。selector 为 0 表示「不带 calldata 的纯 ETH 转账」。
    struct Permission {
        address target;
        bytes4 selector;
    }

    /// @notice 某个资产的额度。token == address(0) 表示原生 ETH。
    ///         period == 0 表示整个 session 生命周期内的总额度，不会重置。
    struct TokenLimit {
        address token;
        uint128 limit;
        uint32 period;
    }

    struct SessionConfig {
        uint48 validAfter;
        uint48 validUntil;
        Permission[] permissions;
        TokenLimit[] limits;
    }

    struct Session {
        uint48 validAfter;
        uint48 validUntil;
        uint32 epoch; // 每次重新授权 +1，让旧的权限和额度整体失效
        bool active;
    }

    struct Allowance {
        uint128 limit;
        uint32 period;
        uint48 windowStart;
        uint128 spent;
    }

    /// @custom:storage-location erc7201:hackchris.agentwallet.v1
    struct Layout {
        mapping(address key => Session) sessions;
        mapping(address key => mapping(uint32 epoch => mapping(address target => mapping(bytes4 selector => bool)))) allowed;
        mapping(address key => mapping(uint32 epoch => mapping(address token => Allowance))) allowances;
        mapping(address key => uint256) nonces;
    }

    // keccak256(abi.encode(uint256(keccak256("hackchris.agentwallet.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT = 0x4be8e6d0f2addbc1e721972d8b9844c569a6288fd9aae9be0142b5032948ac00;
    // 重入锁放在 transient storage（EIP-1153），交易结束自动清零。
    // keccak256(abi.encode(uint256(keccak256("hackchris.agentwallet.lock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LOCK_SLOT = 0x042d3a583c421c8f480b75294c4b4fd9eaa385badcbeb0cafc64f8d4e1884e00;

    bytes4 private constant TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant APPROVE = 0x095ea7b3; // approve(address,uint256)

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant EXECUTE_TYPEHASH = keccak256(
        "Execute(address sessionKey,Call[] calls,uint256 nonce,uint256 deadline)Call(address target,uint256 value,bytes data)"
    );

    // ------------------------------------------------------------------
    // 事件与错误
    // ------------------------------------------------------------------

    event SessionGranted(address indexed key, uint32 epoch, uint48 validAfter, uint48 validUntil);
    event SessionRevoked(address indexed key);
    event SessionExecuted(address indexed key, uint256 nonce, uint256 callCount);

    error OnlySelf();
    error InvalidSessionKey();
    error InvalidWindow();
    error SessionInactive();
    error SessionNotYetValid();
    error SessionExpired();
    error SelfCallForbidden();
    error CallNotAllowed(address target, bytes4 selector);
    error TokenSelectorForbidden(address token, bytes4 selector);
    error MalformedCalldata();
    error NoLimitForAsset(address token);
    error LimitExceeded(address token, uint256 requested, uint256 remaining);
    error BadSignature();
    error BadNonce(uint256 expected, uint256 got);
    error SignatureExpired();
    error Reentrancy();

    // ------------------------------------------------------------------
    // 修饰器
    // ------------------------------------------------------------------

    /// @dev 只有 EOA 本人能管理：用户给自己的地址发交易时，msg.sender == address(this)。
    ///      注意这里不需要也不应该有 initialize()：「谁是 owner」由地址本身决定，
    ///      不存在「部署后、初始化前被别人抢先初始化」的窗口。
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = LOCK_SLOT;
        uint256 locked;
        assembly {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // 主人操作
    // ------------------------------------------------------------------

    /// @notice 主人批量执行任意调用（不受 session 规则限制）。
    function execute(Call[] calldata calls) external payable onlySelf nonReentrant {
        for (uint256 i; i < calls.length; ++i) {
            _call(calls[i]);
        }
    }

    /// @notice 授予或重新授予一个 session key。重新授予会让旧的权限和已用额度全部作废。
    function grantSession(address key, SessionConfig calldata cfg) external onlySelf {
        if (key == address(0) || key == address(this)) revert InvalidSessionKey();
        if (cfg.validUntil <= cfg.validAfter || cfg.validUntil <= block.timestamp) revert InvalidWindow();

        Layout storage $ = _layout();
        Session storage s = $.sessions[key];
        uint32 epoch = s.epoch + 1;
        s.epoch = epoch;
        s.validAfter = cfg.validAfter;
        s.validUntil = cfg.validUntil;
        s.active = true;

        for (uint256 i; i < cfg.permissions.length; ++i) {
            Permission calldata p = cfg.permissions[i];
            // 授权阶段就拒绝指向钱包自己的权限，执行阶段还会再拦一次
            if (p.target == address(this)) revert SelfCallForbidden();
            $.allowed[key][epoch][p.target][p.selector] = true;
        }
        for (uint256 i; i < cfg.limits.length; ++i) {
            TokenLimit calldata l = cfg.limits[i];
            $.allowances[key][epoch][l.token] =
                Allowance({limit: l.limit, period: l.period, windowStart: uint48(block.timestamp), spent: 0});
        }

        emit SessionGranted(key, epoch, cfg.validAfter, cfg.validUntil);
    }

    /// @notice 立即撤销 session key。
    function revokeSession(address key) external onlySelf {
        _layout().sessions[key].active = false;
        emit SessionRevoked(key);
    }

    // ------------------------------------------------------------------
    // agent 操作
    // ------------------------------------------------------------------

    /// @notice session key 自己发交易（需要 agent 持有 gas）。
    function executeAsSession(Call[] calldata calls) external nonReentrant {
        address key = msg.sender;
        uint256 nonce = _layout().nonces[key]++;
        _executeSession(key, calls);
        emit SessionExecuted(key, nonce, calls.length);
    }

    /// @notice 任何人（relayer / facilitator）代发，凭 session key 的 EIP-712 签名。
    /// @dev 签名域里的 verifyingContract 是 address(this)，也就是用户 EOA：
    ///      同一个签名拿到别的用户钱包、别的链上都无效。nonce 防重放，deadline 防签名被长期囤积。
    function executeWithSession(
        address key,
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (block.timestamp > deadline) revert SignatureExpired();
        Layout storage $ = _layout();
        uint256 expected = $.nonces[key];
        if (nonce != expected) revert BadNonce(expected, nonce);
        $.nonces[key] = expected + 1;

        bytes32 digest = hashExecute(key, calls, nonce, deadline);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != key) revert BadSignature();

        _executeSession(key, calls);
        emit SessionExecuted(key, nonce, calls.length);
    }

    // ------------------------------------------------------------------
    // 查询
    // ------------------------------------------------------------------

    function sessionOf(address key) external view returns (Session memory) {
        return _layout().sessions[key];
    }

    function nonceOf(address key) external view returns (uint256) {
        return _layout().nonces[key];
    }

    function isAllowed(address key, address target, bytes4 selector) external view returns (bool) {
        Layout storage $ = _layout();
        return $.allowed[key][$.sessions[key].epoch][target][selector];
    }

    /// @notice 当前周期还能花多少。
    function remaining(address key, address token) external view returns (uint256) {
        Layout storage $ = _layout();
        Allowance memory a = $.allowances[key][$.sessions[key].epoch][token];
        if (a.limit == 0) return 0;
        if (a.period != 0 && block.timestamp >= uint256(a.windowStart) + a.period) return a.limit;
        return a.limit - a.spent;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("AgentWallet7702"), keccak256("1"), block.chainid, address(this)
            )
        );
    }

    function hashExecute(address key, Call[] calldata calls, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            callHashes[i] =
                keccak256(abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_TYPEHASH, key, keccak256(abi.encodePacked(callHashes)), nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ------------------------------------------------------------------
    // 内部逻辑
    // ------------------------------------------------------------------

    function _executeSession(address key, Call[] calldata calls) private {
        Layout storage $ = _layout();
        Session memory s = $.sessions[key];
        if (!s.active) revert SessionInactive();
        if (block.timestamp < s.validAfter) revert SessionNotYetValid();
        if (block.timestamp >= s.validUntil) revert SessionExpired();

        for (uint256 i; i < calls.length; ++i) {
            _enforce($, key, s.epoch, calls[i]); // 先检查、先记账
            _call(calls[i]); // 再执行
        }
    }

    function _enforce(Layout storage $, address key, uint32 epoch, Call calldata c) private {
        // 1. 绝不允许 session 调钱包自己：否则它可以给自己 grantSession，额度形同虚设
        if (c.target == address(this)) revert SelfCallForbidden();

        // 2. (合约, 函数) 白名单，默认拒绝
        bytes4 selector;
        if (c.data.length == 0) {
            selector = bytes4(0);
        } else {
            if (c.data.length < 4) revert MalformedCalldata();
            selector = bytes4(c.data[:4]);
        }
        if (!$.allowed[key][epoch][c.target][selector]) revert CallNotAllowed(c.target, selector);

        // 3. 原生 ETH 计入额度
        if (c.value > 0) _spend($, key, epoch, address(0), c.value);

        // 4. 被限额的 token 只能走 transfer / approve，金额从 calldata 里解出来记账。
        //    approve 也记账：授权本身就是「花钱的权力」，否则 approve 无限额度就能绕过限额。
        bool trackedToken = $.allowances[key][epoch][c.target].limit != 0;
        if (selector == TRANSFER || selector == APPROVE) {
            if (c.data.length != 68) revert MalformedCalldata();
            uint256 amount = abi.decode(c.data[36:68], (uint256));
            _spend($, key, epoch, c.target, amount);
        } else if (trackedToken) {
            revert TokenSelectorForbidden(c.target, selector);
        }
    }

    function _spend(Layout storage $, address key, uint32 epoch, address token, uint256 amount) private {
        Allowance storage a = $.allowances[key][epoch][token];
        if (a.limit == 0) revert NoLimitForAsset(token);

        if (a.period != 0 && block.timestamp >= uint256(a.windowStart) + a.period) {
            a.windowStart = uint48(block.timestamp);
            a.spent = 0;
        }
        uint256 left = a.limit - a.spent;
        if (amount > left) revert LimitExceeded(token, amount, left);
        // amount <= left <= limit，而 limit 本身是 uint128，所以不会截断
        // forge-lint: disable-next-line(unsafe-typecast)
        a.spent += uint128(amount);
    }

    function _call(Call calldata c) private {
        (bool ok, bytes memory ret) = c.target.call{value: c.value}(c.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _layout() private pure returns (Layout storage $) {
        bytes32 slot = LAYOUT_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
