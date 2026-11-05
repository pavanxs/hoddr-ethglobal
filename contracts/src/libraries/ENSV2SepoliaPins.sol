// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Reviewed ENSv2 Sepolia deployment, commit 07e55a056f5b6a9c90119f501bdd05714e67dddd.
/// @dev Runtime hashes include immutables. These are not mainnet or generic L2 addresses.
library ENSV2SepoliaPins {
    address internal constant ROOT = 0xB458D6a3a77919449d03e7A6903C26827c1eC43f;
    address internal constant ETH_REGISTRY = 0xD4eBcbBdF463C9c45784603Db0dDD499BC44A8B4;
    address internal constant FACTORY = 0xDa70306C98E97eCe36F997a21368e53298572991;
    address internal constant USER_IMPLEMENTATION = 0x9BD8a88719068D09ecee662f36C0E3856708366a;
    bytes32 internal constant SYSTEM_CODE_HASH =
        0xddb7698fc2857f7a9e726491025fead241791f113a19714149db8cbf87688e98;
    bytes32 internal constant FACTORY_CODE_HASH =
        0x141dc0d5ee8c60ae9b9cce12c870d3babc28719602238ee0f77016a9f1916265;
    bytes32 internal constant USER_CODE_HASH =
        0xed6d71bc90b0882fa63ef78a8dddabff2730b4c1cab9eab2ad91fa2aacd269f7;
}
