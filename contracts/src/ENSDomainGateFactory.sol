// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ENSDomainGate} from "./ENSDomainGate.sol";
import {IENSDomainGateFactory} from "./interfaces/IENSDomainGateFactory.sol";
import {ENSV2SepoliaPins} from "./libraries/ENSV2SepoliaPins.sol";

/// @notice Deploys only the reviewed ENS gate implementation under one fixed trust configuration.
/// @dev LaunchpadFactory must pin this factory, not accept an arbitrary lookalike gate/factory.
///      No owner, arbitrary registration, config setter or upgrade mechanism exists.
contract ENSDomainGateFactory is IENSDomainGateFactory {
    ENSDomainGate.TrustConfig private _config; // Assigned only in the constructor.
    uint256 public immutable deploymentChainId;
    bool public immutable localTestOnly;
    mapping(address gate => bool recognized) public override isGate;
    mapping(bytes32 parentNamehash => address gate) public override gateForParent;

    error InvalidTrustConfiguration();
    error UnsupportedChain(uint256 chainId);
    error WrongChain(uint256 expected, uint256 actual);
    error UnsupportedParent();
    error ParentUnavailable(ENSDomainGate.Reason reason, uint256 labelIndex);

    event GateCreated(address indexed gate, bytes32 indexed parentNamehash, string parentDomain, bool localTestOnly);

    constructor(ENSDomainGate.TrustConfig memory config) {
        if (config.localTestOnly) {
            if (block.chainid != 31337 && block.chainid != 1337) revert UnsupportedChain(block.chainid);
        } else {
            if (block.chainid != 11155111) revert UnsupportedChain(block.chainid);
            if (config.rootRegistry != ENSV2SepoliaPins.ROOT || config.ethRegistry != ENSV2SepoliaPins.ETH_REGISTRY
                || config.factory != ENSV2SepoliaPins.FACTORY || config.userRegistryImplementation != ENSV2SepoliaPins.USER_IMPLEMENTATION
                || config.rootCodeHash != ENSV2SepoliaPins.SYSTEM_CODE_HASH || config.ethCodeHash != ENSV2SepoliaPins.SYSTEM_CODE_HASH
                || config.factoryCodeHash != ENSV2SepoliaPins.FACTORY_CODE_HASH
                || config.implementationCodeHash != ENSV2SepoliaPins.USER_CODE_HASH) revert InvalidTrustConfiguration();
        }
        if (config.rootRegistry.code.length == 0 || config.ethRegistry.code.length == 0
            || config.factory.code.length == 0 || config.userRegistryImplementation.code.length == 0
            || config.rootRegistry.codehash != config.rootCodeHash || config.ethRegistry.codehash != config.ethCodeHash
            || config.factory.codehash != config.factoryCodeHash
            || config.userRegistryImplementation.codehash != config.implementationCodeHash) {
            revert InvalidTrustConfiguration();
        }
        // Each created ENSDomainGate independently enforces canonical Sepolia addresses/hashes,
        // distinct targets, actual parent traversal, and the strict label policy before registration.
        _config = config;
        deploymentChainId = block.chainid;
        localTestOnly = config.localTestOnly;
    }

    function create(string[] calldata parentLabels) external override returns (address gate) {
        if (block.chainid != deploymentChainId) revert WrongChain(deploymentChainId, block.chainid);
        uint256 count = parentLabels.length;
        if (count < 2 || count > 8) revert UnsupportedParent();
        bytes32 node;
        for (uint256 i; i < count; ++i) {
            node = keccak256(abi.encodePacked(node, keccak256(bytes(parentLabels[i]))));
        }
        gate = gateForParent[node];
        if (gate != address(0)) {
            ENSDomainGate.Eligibility memory current = ENSDomainGate(gate).inspectParent();
            if (!current.eligible) revert ParentUnavailable(current.reason, current.labelIndex);
            return gate;
        }
        ENSDomainGate created = new ENSDomainGate(_config, parentLabels);
        gate = address(created);
        isGate[gate] = true;
        gateForParent[node] = gate;
        emit GateCreated(gate, node, created.parentDomain(), localTestOnly);
    }

    function trustConfig() external view returns (ENSDomainGate.TrustConfig memory) { return _config; }
}
