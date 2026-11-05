// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice ABI for the official World ID 3.0 Router's Orb proof check.
/// @dev Source: https://docs.world.org/world-id/id/on-chain.md
///      This is the group-aware Router ABI, not the underlying identity-manager ABI.
interface IWorldIDV3 {
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external view;
}
