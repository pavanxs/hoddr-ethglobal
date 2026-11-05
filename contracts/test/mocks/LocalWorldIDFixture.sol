// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IWorldIDV3} from "../../src/interfaces/IWorldIDV3.sol";

/// @notice LOCAL TEST CHAIN ONLY. An exact-input fixture allowlist, NOT World ID cryptography.
/// @dev Never deploy or describe this contract as a real human-verification provider.
contract LocalWorldIDFixture is IWorldIDV3 {
    address public immutable fixtureOwner;
    bool public constant localTestOnly = true;
    bool public forceFailure;
    mapping(bytes32 fixture => bool allowed) private _allowed;

    error LocalChainOnly();
    error FixtureOwnerOnly();
    error InvalidFixture();

    constructor() {
        if (block.chainid != 31337 && block.chainid != 1337) revert LocalChainOnly();
        fixtureOwner = msg.sender;
    }

    function allowFixture(
        uint256 root,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external {
        if (msg.sender != fixtureOwner) revert FixtureOwnerOnly();
        _allowed[keccak256(abi.encode(root, uint256(1), signalHash, nullifierHash, externalNullifierHash, proof))] = true;
    }

    function setForceFailure(bool fail) external {
        if (msg.sender != fixtureOwner) revert FixtureOwnerOnly();
        forceFailure = fail;
    }

    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external view override {
        if (forceFailure || groupId != 1
            || !_allowed[keccak256(abi.encode(root, groupId, signalHash, nullifierHash, externalNullifierHash, proof))]) {
            revert InvalidFixture();
        }
    }
}
