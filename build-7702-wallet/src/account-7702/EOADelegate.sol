// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSA} from "../lib/ECDSA.sol";

/// @title EOADelegate
/// @notice Contract code that an EOA delegates to via EIP-7702 (SET_CODE_TX_TYPE 0x04).
///         After delegation, calls to the EOA execute *this code* with
///         `address(this) == EOA` and storage scoped to the EOA's address.
///
///   What this contract gives the EOA
///   --------------------------------
///   1. `execute(target, value, data)`  — direct call (msg.sender must be the EOA itself)
///   2. `executeBatch(calls[])`         — atomic multi-call
///   3. `executeWithSig(...)`           — sponsored execution: anyone can submit; signature
///                                        must be by the EOA's private key
///   4. session keys (added/removed by the EOA), can run a scoped subset of calls
///
///   Storage model
///   -------------
///   Storage lives on the EOA's address (per EIP-7702). To avoid colliding with future
///   delegate upgrades we use EIP-7201 namespaced storage.
///
///   Security notes
///   --------------
///   * Replay protection by per-EOA nonce on `executeWithSig` and session-key calls.
///   * Personal-message signatures bind chain, account and nonce (NOT EIP-712).
///   * Session keys are bounded by `validUntil` and an optional target whitelist
///     (`maxCalls` cap is left as an exercise — see deep-dive/session-key-design.md).
contract EOADelegate {
    /// @custom:storage-location erc7201:eoadelegate.main
    struct MainStorage {
        uint256 nonce;
        mapping(address => SessionKey) sessionKeys;
    }

    struct SessionKey {
        uint48 validUntil;
        uint48 validAfter;
        // bit-packed flags; bit 0 = enabled
        uint16 flags;
        // optional whitelist; address(0) = anywhere
        address allowedTarget;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    // EIP-7201 namespaced slot. Solidity ≤ 0.8.27 does NOT evaluate nested
    // keccak256 at compile time, so we hardcode the precomputed literal and
    // pin it with `test_StorageSlotMatchesFormula` in EOADelegate.t.sol:
    //   slot = keccak256(abi.encode(uint256(keccak256("eoadelegate.main")) - 1))
    //          & ~bytes32(uint256(0xff))
    //
    // The trailing-byte mask leaves the reserved low byte zero and lets a v2
    // delegate ("eoadelegate.main.v2") live in a non-colliding slot on the
    // same EOA.
    bytes32 private constant MAIN_STORAGE_SLOT =
        0xe34bdf1170507d0c3bb392e10bbb9ffadcd2cfe0328b0b655d1e95943c490100;

    bytes32 private constant EXECUTE_TYPEHASH =
        keccak256("Execute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)");

    bytes32 private constant SESSION_EXECUTE_TYPEHASH = keccak256(
        "SessionExecute(address target,uint256 value,bytes data,uint256 nonce,uint256 chainId,address account)"
    );

    event Executed(address indexed target, uint256 value, bytes data);
    event SessionKeyAdded(address indexed key, uint48 validUntil, address allowedTarget);
    event SessionKeyRemoved(address indexed key);
    event NonceUsed(uint256 nonce);

    error NotSelf();
    error BadSignature();
    error SessionKeyExpired();
    error SessionKeyDisabled();
    error SessionTargetForbidden();
    error CallFailed();

    // -------- self-only entrypoints --------

    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(this)) revert NotSelf();
        return _exec(target, value, data);
    }

    function executeBatch(Call[] calldata calls) external returns (bytes[] memory results) {
        if (msg.sender != address(this)) revert NotSelf();
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            results[i] = _exec(calls[i].target, calls[i].value, calls[i].data);
        }
    }

    // -------- sponsored execution: anyone can submit, EOA must sign --------

    function executeWithSig(address target, uint256 value, bytes calldata data, bytes calldata sig)
        external
        returns (bytes memory)
    {
        MainStorage storage $ = _store();
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, target, value, keccak256(data), $.nonce, block.chainid, address(this)));
        bytes32 digest = ECDSA.toEthSignedMessageHash(structHash);
        address signer = ECDSA.recover(digest, sig);
        if (signer != address(this)) revert BadSignature();
        emit NonceUsed($.nonce);
        unchecked {
            $.nonce++;
        }
        return _exec(target, value, data);
    }

    // -------- session keys --------

    function addSessionKey(address key, uint48 validUntil, address allowedTarget) external {
        if (msg.sender != address(this)) revert NotSelf();
        // Changing permissions invalidates ALL pending application signatures.
        _store().nonce++;
        _store().sessionKeys[key] = SessionKey({
            validUntil: validUntil,
            validAfter: uint48(block.timestamp),
            flags: 1,
            allowedTarget: allowedTarget
        });
        emit SessionKeyAdded(key, validUntil, allowedTarget);
    }

    function removeSessionKey(address key) external {
        if (msg.sender != address(this)) revert NotSelf();
        _store().nonce++;
        delete _store().sessionKeys[key];
        emit SessionKeyRemoved(key);
    }

    function getSessionKey(address key) external view returns (SessionKey memory) {
        return _store().sessionKeys[key];
    }

    function executeBySession(address target, uint256 value, bytes calldata data, bytes calldata sig)
        external
        returns (bytes memory)
    {
        MainStorage storage $ = _store();
        bytes32 structHash = keccak256(
            abi.encode(SESSION_EXECUTE_TYPEHASH, target, value, keccak256(data), $.nonce, block.chainid, address(this))
        );
        // Recover session key from sig (note: session sig is signed by the SESSION key, not the EOA).
        bytes32 digest = ECDSA.toEthSignedMessageHash(structHash);
        address sessionSigner = ECDSA.recover(digest, sig);
        SessionKey memory sk = $.sessionKeys[sessionSigner];
        if (sk.flags & 1 == 0) revert SessionKeyDisabled();
        if (block.timestamp < sk.validAfter || block.timestamp > sk.validUntil) revert SessionKeyExpired();
        // A session must never enter the account's self-only admin functions.
        if (target == address(this)) revert SessionTargetForbidden();
        if (sk.allowedTarget != address(0) && sk.allowedTarget != target) revert SessionTargetForbidden();
        emit NonceUsed($.nonce);
        unchecked {
            $.nonce++;
        }
        return _exec(target, value, data);
    }

    // -------- views --------

    function nonce() external view returns (uint256) {
        return _store().nonce;
    }

    // -------- internal --------

    function _exec(address target, uint256 value, bytes calldata data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            if (ret.length == 0) revert CallFailed();
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit Executed(target, value, data);
        return ret;
    }

    function _store() private pure returns (MainStorage storage $) {
        bytes32 slot = MAIN_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @notice Accept ETH so paymasters / sponsors can fund the EOA prior to a call.
    receive() external payable {}
}
