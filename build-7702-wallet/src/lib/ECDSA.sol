// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Tiny ECDSA helper for 65-byte signatures (r || s || v).
library ECDSA {
    error InvalidSignatureLength();
    error InvalidSValue();

    /// @notice Recover signer from a 65-byte sig over `digest`.
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert InvalidSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        // EIP-2: low-s only.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSValue();
        }
        if (v < 27) v += 27;
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "ECDSA: zero");
        return signer;
    }

    function toEthSignedMessageHash(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }
}
