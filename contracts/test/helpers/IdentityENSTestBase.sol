// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface VmIdentityENS {
    function chainId(uint256 newChainId) external;
    function warp(uint256 newTimestamp) external;
    function prank(address caller) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata reason) external;
    function etch(address target, bytes calldata code) external;
}

/// @dev Tiny test-only assertion base; no external test dependency or environment reads.
abstract contract IdentityENSTestBase {
    VmIdentityENS internal constant vm = VmIdentityENS(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool value) internal pure { require(value, "expected true"); }
    function assertFalse(bool value) internal pure { require(!value, "expected false"); }
    function assertEq(uint256 a, uint256 b) internal pure { require(a == b, "uint mismatch"); }
    function assertEq(address a, address b) internal pure { require(a == b, "address mismatch"); }
    function assertEq(bytes32 a, bytes32 b) internal pure { require(a == b, "bytes32 mismatch"); }
    function assertEq(string memory a, string memory b) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), "string mismatch");
    }
}
