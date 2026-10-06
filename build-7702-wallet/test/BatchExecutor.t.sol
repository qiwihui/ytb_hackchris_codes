// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BatchExecutor} from "../src/account-7702/BatchExecutor.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice "The minimum viable 7702 wallet": pure batching, ~30 lines.
contract BatchExecutorTest is Test {
    BatchExecutor internal logic;
    address internal eoa;
    MockUSDC internal usdc;

    function setUp() public {
        logic = new BatchExecutor();
        eoa = makeAddr("eoa");
        vm.etch(eoa, address(logic).code);
        usdc = new MockUSDC();
        usdc.mint(eoa, 1_000e6);
    }

    function test_ApproveAndTransferAtomically() public {
        address spender = address(0xABCD);
        address recipient = address(0xCAFE);

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(address(usdc), 0, abi.encodeCall(MockUSDC.approve, (spender, 100e6)));
        calls[1] = BatchExecutor.Call(address(usdc), 0, abi.encodeCall(MockUSDC.transfer, (recipient, 40e6)));

        vm.prank(eoa);
        BatchExecutor(payable(eoa)).executeBatch(calls);

        assertEq(usdc.allowance(eoa, spender), 100e6);
        assertEq(usdc.balanceOf(recipient), 40e6);
    }

    function test_ExternalCallerRejected() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](0);
        vm.expectRevert(BatchExecutor.NotSelf.selector);
        BatchExecutor(payable(eoa)).executeBatch(calls);
    }
}
