// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {EOADelegate} from "../src/account-7702/EOADelegate.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract SessionKeyTest is Test {
    EOADelegate internal logic;
    address internal eoa;
    uint256 internal eoaPk;
    address internal sessionKey;
    uint256 internal sessionPk;
    address internal stranger;
    uint256 internal strangerPk;
    address internal sponsor = address(0xBEEF);
    MockUSDC internal usdc;
    MockUSDC internal otherToken;

    bytes32 internal constant SESSION_TYPEHASH = keccak256(
        "SessionExecute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)"
    );

    function setUp() public {
        logic = new EOADelegate();
        (eoa, eoaPk) = makeAddrAndKey("eoa");
        (sessionKey, sessionPk) = makeAddrAndKey("session");
        (stranger, strangerPk) = makeAddrAndKey("stranger");
        vm.etch(eoa, address(logic).code);
        usdc = new MockUSDC();
        otherToken = new MockUSDC();
        usdc.mint(eoa, 1_000e6);
        otherToken.mint(eoa, 1_000e6);
        vm.deal(eoa, 1 ether);
        vm.deal(sponsor, 1 ether);
    }

    function _signSession(uint256 pk, address target, bytes memory data, uint256 nonce_)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(SESSION_TYPEHASH, target, uint256(0), keccak256(data), nonce_, block.chainid, eoa)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_SessionKey_HappyPath_ScopedToOneToken() public {
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));

        bytes memory data = abi.encodeCall(MockUSDC.transfer, (address(0xCAFE), 3e6));
        bytes memory sig = _signSession(sessionPk, address(usdc), data, EOADelegate(payable(eoa)).nonce());

        vm.prank(sponsor);
        EOADelegate(payable(eoa)).executeBySession(address(usdc), 0, data, sig);
        assertEq(usdc.balanceOf(address(0xCAFE)), 3e6);
    }

    function test_SessionKey_RejectsWrongTarget() public {
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));

        bytes memory data = abi.encodeCall(MockUSDC.transfer, (address(0xCAFE), 1e6));
        bytes memory sig = _signSession(sessionPk, address(otherToken), data, EOADelegate(payable(eoa)).nonce());

        vm.prank(sponsor);
        vm.expectRevert(EOADelegate.SessionTargetForbidden.selector);
        EOADelegate(payable(eoa)).executeBySession(address(otherToken), 0, data, sig);
    }

    function test_SessionKey_RejectsAfterExpiry() public {
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 hours), address(usdc));

        vm.warp(block.timestamp + 2 hours);

        bytes memory data = abi.encodeCall(MockUSDC.transfer, (address(0xCAFE), 1e6));
        bytes memory sig = _signSession(sessionPk, address(usdc), data, EOADelegate(payable(eoa)).nonce());

        vm.prank(sponsor);
        vm.expectRevert(EOADelegate.SessionKeyExpired.selector);
        EOADelegate(payable(eoa)).executeBySession(address(usdc), 0, data, sig);
    }

    function test_SessionKey_RejectsUnknownSigner() public {
        // No session key added for `stranger`.
        bytes memory data = abi.encodeCall(MockUSDC.transfer, (address(0xCAFE), 1e6));
        bytes memory sig = _signSession(strangerPk, address(usdc), data, EOADelegate(payable(eoa)).nonce());

        vm.prank(sponsor);
        vm.expectRevert(EOADelegate.SessionKeyDisabled.selector);
        EOADelegate(payable(eoa)).executeBySession(address(usdc), 0, data, sig);
    }

    function test_SessionKey_Revocation() public {
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));

        vm.prank(eoa);
        EOADelegate(payable(eoa)).removeSessionKey(sessionKey);

        bytes memory data = abi.encodeCall(MockUSDC.transfer, (address(0xCAFE), 1e6));
        bytes memory sig = _signSession(sessionPk, address(usdc), data, EOADelegate(payable(eoa)).nonce());

        vm.prank(sponsor);
        vm.expectRevert(EOADelegate.SessionKeyDisabled.selector);
        EOADelegate(payable(eoa)).executeBySession(address(usdc), 0, data, sig);
    }
    function test_SessionKey_CannotCallSelf() public {
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(0));
        bytes memory data = abi.encodeCall(EOADelegate.addSessionKey, (stranger, uint48(block.timestamp + 1 days), address(0)));
        bytes memory sig = _signSession(sessionPk, eoa, data, EOADelegate(payable(eoa)).nonce());
        vm.expectRevert(EOADelegate.SessionTargetForbidden.selector);
        EOADelegate(payable(eoa)).executeBySession(eoa, 0, data, sig);
    }

    function test_SessionKey_RejectsCrossAccountReplay() public {
        address second = makeAddr("second");
        vm.etch(second, address(logic).code);
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));
        vm.prank(second);
        EOADelegate(payable(second)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));
        usdc.mint(second, 100e6);
        bytes memory data = abi.encodeCall(MockUSDC.transfer, (stranger, 1e6));
        bytes memory sig = _signSession(sessionPk, address(usdc), data, EOADelegate(payable(eoa)).nonce());
        vm.expectRevert(EOADelegate.SessionKeyDisabled.selector);
        EOADelegate(payable(second)).executeBySession(address(usdc), 0, data, sig);
        assertEq(usdc.balanceOf(second), 100e6);
    }

    function test_SessionKey_OldSignatureStaysInvalidAfterRegrant() public {
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));
        bytes memory data = abi.encodeCall(MockUSDC.transfer, (stranger, 1e6));
        bytes memory sig = _signSession(sessionPk, address(usdc), data, EOADelegate(payable(eoa)).nonce());
        vm.prank(eoa);
        EOADelegate(payable(eoa)).removeSessionKey(sessionKey);
        vm.prank(eoa);
        EOADelegate(payable(eoa)).addSessionKey(sessionKey, uint48(block.timestamp + 1 days), address(usdc));
        vm.expectRevert(EOADelegate.SessionKeyDisabled.selector);
        EOADelegate(payable(eoa)).executeBySession(address(usdc), 0, data, sig);
    }

}
