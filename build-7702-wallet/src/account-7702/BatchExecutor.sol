// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title BatchExecutor
/// @notice The minimum viable EIP-7702 delegate: pure batching, no signatures,
///         no session keys, no namespaced storage. Used in the video to make
///         one point clear — once an EOA points its `code` at *any* contract
///         via the 0x04 SET_CODE_TX_TYPE, that EOA gets contract-style entry
///         points for free.
///
///   Why a separate, tiny contract?
///   ------------------------------
///   We delegate to this first, see "atomic approve+swap+transfer in one tx"
///   actually work, and only then graduate to EOADelegate which adds the
///   harder parts (sponsored execution, session keys, replay protection).
///
///   Self-only guard
///   ---------------
///   After delegation, `address(this) == EOA`, so `msg.sender == address(this)`
///   is *exactly* the check "the EOA itself signed the outer transaction".
///   The outer tx is signed with the EOA's key, so authorization is implicit
///   in the tx signature — we just need to refuse external entries.
contract BatchExecutor {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    event Executed(address indexed target, uint256 value, bytes data);
    error NotSelf();
    error CallFailed(uint256 index, bytes ret);

    function executeBatch(Call[] calldata calls) external returns (bytes[] memory results) {
        if (msg.sender != address(this)) revert NotSelf();
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
            results[i] = ret;
            emit Executed(calls[i].target, calls[i].value, calls[i].data);
        }
    }

    receive() external payable {}
}
