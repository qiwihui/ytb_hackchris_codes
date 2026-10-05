// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentWallet7702} from "../src/AgentWallet7702.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract AgentWallet7702Test is Test {
    AgentWallet7702 impl;
    AgentWallet7702 wallet; // 用户 EOA 地址，代码来自 7702 委托
    MockUSDC usdc;

    uint256 ownerPk = 0xA11CE;
    uint256 agentPk = 0xA6E47;
    address owner;
    address agent;
    address merchant = makeAddr("merchant");
    address attacker = makeAddr("attacker");
    address relayer = makeAddr("relayer");

    uint128 constant DAILY_USDC = 100e6; // 每天 100 USDC
    uint128 constant ETH_CAP = 0.1 ether; // 整个 session 最多 0.1 ETH

    function setUp() public {
        owner = vm.addr(ownerPk);
        agent = vm.addr(agentPk);

        impl = new AgentWallet7702();
        usdc = new MockUSDC();

        // EIP-7702：owner 签一个授权，把自己 EOA 的代码指向 impl
        vm.signAndAttachDelegation(address(impl), ownerPk);
        wallet = AgentWallet7702(payable(owner));

        usdc.mint(owner, 1_000e6);
        vm.deal(owner, 10 ether);

        _grantDefault();
    }

    // ------------------------------------------------------------------
    // 工具函数
    // ------------------------------------------------------------------

    function _defaultConfig() internal view returns (AgentWallet7702.SessionConfig memory cfg) {
        cfg.validAfter = uint48(block.timestamp);
        cfg.validUntil = uint48(block.timestamp + 7 days);
        cfg.permissions = new AgentWallet7702.Permission[](2);
        cfg.permissions[0] = AgentWallet7702.Permission(address(usdc), usdc.transfer.selector);
        cfg.permissions[1] = AgentWallet7702.Permission(merchant, bytes4(0)); // 只能给商家打 ETH
        cfg.limits = new AgentWallet7702.TokenLimit[](2);
        cfg.limits[0] = AgentWallet7702.TokenLimit(address(usdc), DAILY_USDC, 1 days);
        cfg.limits[1] = AgentWallet7702.TokenLimit(address(0), ETH_CAP, 0);
    }

    function _grantDefault() internal {
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        vm.prank(owner); // msg.sender == address(this)：EOA 给自己发交易
        wallet.grantSession(agent, cfg);
    }

    function _usdcPay(address to, uint256 amount) internal view returns (AgentWallet7702.Call[] memory calls) {
        calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(address(usdc), 0, abi.encodeCall(usdc.transfer, (to, amount)));
    }

    function _sign(AgentWallet7702 w, AgentWallet7702.Call[] memory calls, uint256 nonce, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = w.hashExecute(vm.addr(pk), calls, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// relayer 代发一笔由 agent 签名的请求
    function _relay(AgentWallet7702.Call[] memory calls) internal {
        uint256 nonce = wallet.nonceOf(agent);
        uint256 deadline = block.timestamp + 10 minutes;
        bytes memory sig = _sign(wallet, calls, nonce, deadline, agentPk);
        vm.prank(relayer);
        wallet.executeWithSession(agent, calls, nonce, deadline, sig);
    }

    // ------------------------------------------------------------------
    // 7702 基本面
    // ------------------------------------------------------------------

    function test_delegationInstalled() public view {
        // 7702 委托后，EOA 的 code 是 0xef0100 || impl 地址
        assertEq(owner.code, abi.encodePacked(hex"ef0100", address(impl)));
    }

    // ------------------------------------------------------------------
    // 正常路径
    // ------------------------------------------------------------------

    function test_agentPaysWithinLimit_viaRelayer() public {
        _relay(_usdcPay(merchant, 30e6));
        assertEq(usdc.balanceOf(merchant), 30e6);
        assertEq(wallet.remaining(agent, address(usdc)), 70e6);
        assertEq(wallet.nonceOf(agent), 1);
    }

    function test_agentPaysWithinLimit_direct() public {
        vm.prank(agent);
        wallet.executeAsSession(_usdcPay(merchant, 40e6));
        assertEq(usdc.balanceOf(merchant), 40e6);
    }

    function test_agentPaysEthWithinCap() public {
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(merchant, 0.05 ether, "");
        _relay(calls);
        assertEq(merchant.balance, 0.05 ether);
        assertEq(wallet.remaining(agent, address(0)), 0.05 ether);
    }

    function test_batchCountsCumulatively() public {
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](2);
        calls[0] = _usdcPay(merchant, 60e6)[0];
        calls[1] = _usdcPay(merchant, 50e6)[0]; // 两笔加起来 110 > 100
        uint256 nonce = wallet.nonceOf(agent);
        bytes memory sig = _sign(wallet, calls, nonce, block.timestamp + 1, agentPk);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWallet7702.LimitExceeded.selector, address(usdc), 50e6, 40e6)
        );
        wallet.executeWithSession(agent, calls, nonce, block.timestamp + 1, sig);
    }

    // ------------------------------------------------------------------
    // 额度
    // ------------------------------------------------------------------

    function test_revert_overDailyLimit() public {
        _relay(_usdcPay(merchant, 80e6));
        AgentWallet7702.Call[] memory calls = _usdcPay(merchant, 30e6);
        uint256 nonce = wallet.nonceOf(agent);
        bytes memory sig = _sign(wallet, calls, nonce, block.timestamp + 1, agentPk);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWallet7702.LimitExceeded.selector, address(usdc), 30e6, 20e6)
        );
        wallet.executeWithSession(agent, calls, nonce, block.timestamp + 1, sig);
    }

    function test_limitResetsNextPeriod() public {
        _relay(_usdcPay(merchant, 100e6));
        assertEq(wallet.remaining(agent, address(usdc)), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(wallet.remaining(agent, address(usdc)), DAILY_USDC);
        _relay(_usdcPay(merchant, 100e6));
        assertEq(usdc.balanceOf(merchant), 200e6);
    }

    function test_revert_ethCapIsLifetime() public {
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(merchant, 0.1 ether, "");
        _relay(calls);
        vm.warp(block.timestamp + 3 days); // period = 0，不会重置
        calls[0].value = 1 wei;
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentWallet7702.LimitExceeded.selector, address(0), 1, 0));
        wallet.executeAsSession(calls);
    }

    function test_revert_approveCountsAsSpend() public {
        // 即使把 approve 加进白名单，授权额度也要计入限额，否则「approve 无限」就绕过了
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        AgentWallet7702.Permission[] memory p = new AgentWallet7702.Permission[](2);
        p[0] = cfg.permissions[0];
        p[1] = AgentWallet7702.Permission(address(usdc), usdc.approve.selector);
        cfg.permissions = p;
        vm.prank(owner);
        wallet.grantSession(agent, cfg);

        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(address(usdc), 0, abi.encodeCall(usdc.approve, (attacker, type(uint256).max)));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentWallet7702.LimitExceeded.selector, address(usdc), type(uint256).max, uint256(DAILY_USDC)
            )
        );
        wallet.executeAsSession(calls);
    }

    function test_revert_tokenWithoutLimit() public {
        // 白名单里没有给这个 token 设额度：默认拒绝
        MockUSDC other = new MockUSDC();
        other.mint(owner, 1_000e6);
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        cfg.permissions[1] = AgentWallet7702.Permission(address(other), other.transfer.selector);
        vm.prank(owner);
        wallet.grantSession(agent, cfg);

        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(address(other), 0, abi.encodeCall(other.transfer, (attacker, 1)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentWallet7702.NoLimitForAsset.selector, address(other)));
        wallet.executeAsSession(calls);
    }

    // ------------------------------------------------------------------
    // 白名单与自调用
    // ------------------------------------------------------------------

    function test_revert_targetNotAllowed() public {
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(attacker, 0.01 ether, ""); // 白名单里只有 merchant
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentWallet7702.CallNotAllowed.selector, attacker, bytes4(0)));
        wallet.executeAsSession(calls);
    }

    function test_revert_selectorNotAllowed() public {
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(
            address(usdc), 0, abi.encodeCall(usdc.transferFrom, (owner, attacker, 1))
        );
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWallet7702.CallNotAllowed.selector, address(usdc), usdc.transferFrom.selector)
        );
        wallet.executeAsSession(calls);
    }

    function test_revert_sessionCannotCallWalletItself() public {
        // agent 想给自己「升级」：调用钱包自己的 grantSession
        AgentWallet7702.SessionConfig memory evil = _defaultConfig();
        evil.limits[0].limit = type(uint128).max;
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(owner, 0, abi.encodeCall(wallet.grantSession, (agent, evil)));
        vm.prank(agent);
        vm.expectRevert(AgentWallet7702.SelfCallForbidden.selector);
        wallet.executeAsSession(calls);
    }

    function test_revert_grantPermissionOnSelf() public {
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        cfg.permissions[1] = AgentWallet7702.Permission(owner, wallet.grantSession.selector);
        vm.prank(owner);
        vm.expectRevert(AgentWallet7702.SelfCallForbidden.selector);
        wallet.grantSession(agent, cfg);
    }

    // ------------------------------------------------------------------
    // 时间窗口与撤销
    // ------------------------------------------------------------------

    function test_revert_expired() public {
        vm.warp(block.timestamp + 7 days);
        vm.prank(agent);
        vm.expectRevert(AgentWallet7702.SessionExpired.selector);
        wallet.executeAsSession(_usdcPay(merchant, 1e6));
    }

    function test_revert_notYetValid() public {
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        cfg.validAfter = uint48(block.timestamp + 1 hours);
        vm.prank(owner);
        wallet.grantSession(agent, cfg);
        vm.prank(agent);
        vm.expectRevert(AgentWallet7702.SessionNotYetValid.selector);
        wallet.executeAsSession(_usdcPay(merchant, 1e6));
    }

    function test_revokeStopsSessionImmediately() public {
        _relay(_usdcPay(merchant, 10e6));
        vm.prank(owner);
        wallet.revokeSession(agent);
        vm.prank(agent);
        vm.expectRevert(AgentWallet7702.SessionInactive.selector);
        wallet.executeAsSession(_usdcPay(merchant, 10e6));
    }

    function test_regrantWipesOldPermissions() public {
        // 第一次授权允许给 merchant 打 ETH；第二次授权不包含它
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        AgentWallet7702.Permission[] memory p = new AgentWallet7702.Permission[](1);
        p[0] = cfg.permissions[0];
        cfg.permissions = p;
        vm.prank(owner);
        wallet.grantSession(agent, cfg);

        assertFalse(wallet.isAllowed(agent, merchant, bytes4(0)));
        AgentWallet7702.Call[] memory calls = new AgentWallet7702.Call[](1);
        calls[0] = AgentWallet7702.Call(merchant, 0.01 ether, "");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentWallet7702.CallNotAllowed.selector, merchant, bytes4(0)));
        wallet.executeAsSession(calls);
    }

    // ------------------------------------------------------------------
    // 权限边界
    // ------------------------------------------------------------------

    function test_revert_onlyOwnerCanGrant() public {
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        vm.prank(agent);
        vm.expectRevert(AgentWallet7702.OnlySelf.selector);
        wallet.grantSession(attacker, cfg);
    }

    function test_revert_onlyOwnerCanRevoke() public {
        vm.prank(attacker);
        vm.expectRevert(AgentWallet7702.OnlySelf.selector);
        wallet.revokeSession(agent);
    }

    function test_ownerCanExecuteAnything() public {
        AgentWallet7702.Call[] memory calls = _usdcPay(attacker, 500e6); // 远超 agent 的额度
        vm.prank(owner);
        wallet.execute(calls);
        assertEq(usdc.balanceOf(attacker), 500e6);
    }

    function test_revert_unknownKey() public {
        vm.prank(attacker);
        vm.expectRevert(AgentWallet7702.SessionInactive.selector);
        wallet.executeAsSession(_usdcPay(attacker, 1e6));
    }

    // ------------------------------------------------------------------
    // 签名与重放
    // ------------------------------------------------------------------

    function test_revert_replaySameSignature() public {
        AgentWallet7702.Call[] memory calls = _usdcPay(merchant, 10e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(wallet, calls, 0, deadline, agentPk);
        wallet.executeWithSession(agent, calls, 0, deadline, sig);
        vm.expectRevert(abi.encodeWithSelector(AgentWallet7702.BadNonce.selector, 1, 0));
        wallet.executeWithSession(agent, calls, 0, deadline, sig);
    }

    function test_revert_signatureByWrongKey() public {
        AgentWallet7702.Call[] memory calls = _usdcPay(attacker, 10e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(wallet, calls, 0, deadline, 0xBAD);
        vm.expectRevert(AgentWallet7702.BadSignature.selector);
        wallet.executeWithSession(agent, calls, 0, deadline, sig);
    }

    function test_revert_tamperedCalls() public {
        // relayer 拿到合法签名后把收款人换掉
        AgentWallet7702.Call[] memory calls = _usdcPay(merchant, 10e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(wallet, calls, 0, deadline, agentPk);
        calls[0].data = abi.encodeCall(usdc.transfer, (attacker, 10e6));
        vm.expectRevert(AgentWallet7702.BadSignature.selector);
        wallet.executeWithSession(agent, calls, 0, deadline, sig);
    }

    function test_revert_expiredSignature() public {
        AgentWallet7702.Call[] memory calls = _usdcPay(merchant, 10e6);
        uint256 deadline = block.timestamp + 1 minutes;
        bytes memory sig = _sign(wallet, calls, 0, deadline, agentPk);
        vm.warp(deadline + 1);
        vm.expectRevert(AgentWallet7702.SignatureExpired.selector);
        wallet.executeWithSession(agent, calls, 0, deadline, sig);
    }

    function test_revert_crossWalletReplay() public {
        // 第二个用户 Bob 也给同一个 agent 开了 session
        uint256 bobPk = 0xB0B;
        address bob = vm.addr(bobPk);
        vm.signAndAttachDelegation(address(impl), bobPk);
        AgentWallet7702 bobWallet = AgentWallet7702(payable(bob));
        usdc.mint(bob, 1_000e6);
        AgentWallet7702.SessionConfig memory cfg = _defaultConfig();
        vm.prank(bob);
        bobWallet.grantSession(agent, cfg);

        // agent 给 Alice 钱包签的请求，拿到 Bob 钱包上用：domain 里的 verifyingContract 不同
        AgentWallet7702.Call[] memory calls = _usdcPay(attacker, 10e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigForAlice = _sign(wallet, calls, 0, deadline, agentPk);
        vm.expectRevert(AgentWallet7702.BadSignature.selector);
        bobWallet.executeWithSession(agent, calls, 0, deadline, sigForAlice);
    }

    function test_revert_crossChainReplay() public {
        AgentWallet7702.Call[] memory calls = _usdcPay(merchant, 10e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(wallet, calls, 0, deadline, agentPk);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(AgentWallet7702.BadSignature.selector);
        wallet.executeWithSession(agent, calls, 0, deadline, sig);
    }

    // ------------------------------------------------------------------
    // 模糊测试：同一周期内，不管怎么拆单，总支出都不超过额度
    // ------------------------------------------------------------------

    function testFuzz_neverExceedsDailyLimit(uint64[8] memory amounts) public {
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amt = bound(amounts[i], 1, 60e6);
            vm.prank(agent);
            try wallet.executeAsSession(_usdcPay(merchant, amt)) {
                total += amt;
            } catch {}
        }
        assertLe(total, DAILY_USDC);
        assertEq(usdc.balanceOf(merchant), total);
    }
}
