// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {EOADelegate} from "../src/account-7702/EOADelegate.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Tests for EOADelegate as if attached to an EOA via 7702.
///         We use `vm.etch(eoa, code)` to simulate the post-delegation state:
///         the EOA's address has the delegate's runtime code.
contract EOADelegateTest is Test {
    EOADelegate internal logic; // canonical deployed delegate
    address internal eoa;
    uint256 internal eoaPk;
    MockUSDC internal usdc;
    address internal sponsor = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        logic = new EOADelegate();
        (eoa, eoaPk) = makeAddrAndKey("eoa");
        // Simulate 7702 delegation: etch the delegate runtime code at the EOA.
        vm.etch(eoa, address(logic).code);
        usdc = new MockUSDC();
        usdc.mint(eoa, 1_000e6);
        vm.deal(eoa, 1 ether);
        vm.deal(sponsor, 1 ether);
    }

    function test_StorageSlotMatchesFormula() public {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("eoadelegate.main")) - 1))
            & ~bytes32(uint256(0xff));
        // Observe the slot actually read by the deployed implementation.
        vm.store(eoa, expected, bytes32(uint256(123)));
        assertEq(EOADelegate(payable(eoa)).nonce(), 123);

    }

    function test_Execute_OnlySelf() public {
        bytes memory data = abi.encodeCall(MockUSDC.transfer, (recipient, 10e6));

        // Non-EOA caller is rejected.
        vm.expectRevert(EOADelegate.NotSelf.selector);
        EOADelegate(payable(eoa)).execute(address(usdc), 0, data);

        // EOA itself succeeds.
        vm.prank(eoa);
        EOADelegate(payable(eoa)).execute(address(usdc), 0, data);
        assertEq(usdc.balanceOf(recipient), 10e6);
    }

    function test_ExecuteBatch_Atomic() public {
        EOADelegate.Call[] memory calls = new EOADelegate.Call[](2);
        calls[0] = EOADelegate.Call(address(usdc), 0, abi.encodeCall(MockUSDC.transfer, (recipient, 5e6)));
        calls[1] = EOADelegate.Call(address(usdc), 0, abi.encodeCall(MockUSDC.transfer, (recipient, 7e6)));

        vm.prank(eoa);
        EOADelegate(payable(eoa)).executeBatch(calls);
        assertEq(usdc.balanceOf(recipient), 12e6);
    }

    function test_ExecuteWithSig_SponsoredByThirdParty() public {
        uint256 amount = 25e6;
        bytes memory data = abi.encodeCall(MockUSDC.transfer, (recipient, amount));

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Execute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)"),
                address(usdc),
                uint256(0),
                keccak256(data),
                uint256(0), // nonce
                block.chainid, eoa
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Sponsor (not the EOA) submits the tx and pays gas.
        vm.prank(sponsor);
        EOADelegate(payable(eoa)).executeWithSig(address(usdc), 0, data, sig);
        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(EOADelegate(payable(eoa)).nonce(), 1);
    }

    function test_ExecuteWithSig_RejectsReplay() public {
        bytes memory data = abi.encodeCall(MockUSDC.transfer, (recipient, 1e6));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Execute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)"),
                address(usdc), uint256(0), keccak256(data), uint256(0), block.chainid, eoa
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(sponsor);
        EOADelegate(payable(eoa)).executeWithSig(address(usdc), 0, data, sig);

        // Same signature, nonce already consumed.
        vm.prank(sponsor);
        vm.expectRevert(EOADelegate.BadSignature.selector);
        EOADelegate(payable(eoa)).executeWithSig(address(usdc), 0, data, sig);
    }
    function test_ExecuteBatch_RollsBackEarlierCalls() public {
        EOADelegate.Call[] memory calls = new EOADelegate.Call[](3);
        calls[0] = EOADelegate.Call(address(usdc), 0, abi.encodeCall(MockUSDC.approve, (recipient, 100e6)));
        calls[1] = EOADelegate.Call(address(usdc), 0, abi.encodeCall(MockUSDC.transfer, (recipient, 5e6)));
        calls[2] = EOADelegate.Call(address(usdc), 0, abi.encodeCall(MockUSDC.transfer, (recipient, 2000e6)));
        vm.prank(eoa);
        vm.expectRevert();
        EOADelegate(payable(eoa)).executeBatch(calls);
        assertEq(usdc.balanceOf(recipient), 0);
        assertEq(usdc.balanceOf(eoa), 1000e6);
        assertEq(usdc.allowance(eoa, recipient), 0);
    }

}
