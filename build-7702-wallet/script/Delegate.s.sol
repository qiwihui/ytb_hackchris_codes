// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {EOADelegate} from "../src/account-7702/EOADelegate.sol";
import {BatchExecutor} from "../src/account-7702/BatchExecutor.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Deploy delegate contracts + mock token to local anvil --hardfork prague.
///         The actual SET_CODE_TX_TYPE (0x04) authorization is submitted from
///         `relayer/auth_tx.py` because Foundry's `vm.signAuthorization` cheatcode
///         doesn't broadcast a real 7702 tx — that path lives in Python.
contract DelegateScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        EOADelegate delegate = new EOADelegate();
        BatchExecutor batcher = new BatchExecutor();
        MockUSDC usdc = new MockUSDC();
        usdc.mint(vm.envAddress("USER_ADDR"), 1_000e6);

        console2.log("EOADelegate    ", address(delegate));
        console2.log("BatchExecutor  ", address(batcher));
        console2.log("MockUSDC       ", address(usdc));

        vm.stopBroadcast();
    }
}
