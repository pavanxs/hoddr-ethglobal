// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IENSV2Registry, IENSVerifiableFactory} from "../../src/interfaces/IENSV2Registry.sol";

abstract contract LocalENSFixtureBase {
    address public immutable fixtureOwner;
    bool public constant localTestOnly = true;
    error LocalChainOnly();
    error FixtureOwnerOnly();

    constructor() {
        if (block.chainid != 31337 && block.chainid != 1337) revert LocalChainOnly();
        fixtureOwner = msg.sender;
    }

    modifier onlyFixtureOwner() {
        if (msg.sender != fixtureOwner) revert FixtureOwnerOnly();
        _;
    }
}

/// @notice LOCAL TEST fixture for the reviewed expiry/ownership/forward-link semantics.
/// @dev This is not an official ENS deployment. Provenance is simulated only on local chains.
contract LocalENSRegistryFixture is LocalENSFixtureBase, IENSV2Registry {
    struct Entry { address owner; uint64 expiry; address child; }
    mapping(uint256 id => Entry entry) private _entries;
    mapping(uint256 id => address record) public addressRecord;
    mapping(uint256 id => mapping(address account => bool allowed)) public renewalPermission;
    address public claimedParent;
    string public claimedParentLabel;

    function setName(string calldata label, address owner, uint64 expiry, address child) external onlyFixtureOwner {
        _entries[uint256(keccak256(bytes(label)))] = Entry(owner, expiry, child);
    }

    function transferName(string calldata label, address owner) external onlyFixtureOwner {
        _entries[uint256(keccak256(bytes(label)))].owner = owner;
    }

    function setChild(string calldata label, address child) external onlyFixtureOwner {
        _entries[uint256(keccak256(bytes(label)))].child = child;
    }

    function setExpiry(string calldata label, uint64 expiry) external onlyFixtureOwner {
        _entries[uint256(keccak256(bytes(label)))].expiry = expiry;
    }

    function setAddressRecord(string calldata label, address account) external onlyFixtureOwner {
        addressRecord[uint256(keccak256(bytes(label)))] = account;
    }

    function setRenewalPermission(string calldata label, address account, bool allowed) external onlyFixtureOwner {
        renewalPermission[uint256(keccak256(bytes(label)))][account] = allowed;
    }

    function setClaimedParent(address parent, string calldata label) external onlyFixtureOwner {
        claimedParent = parent;
        claimedParentLabel = label;
    }

    function getParent() external view returns (address, string memory) {
        return (claimedParent, claimedParentLabel);
    }

    function getState(uint256 anyId) external view override returns (State memory state) {
        Entry memory entry = _entries[anyId];
        state.status = block.timestamp >= entry.expiry ? 0 : (entry.owner == address(0) ? 1 : 2);
        state.expiry = entry.expiry;
        state.latestOwner = entry.owner;
        state.tokenId = anyId & ~uint256(type(uint32).max);
        state.resource = state.tokenId;
    }

    function getOwner(uint256 anyId) external view override returns (address) {
        Entry memory entry = _entries[anyId];
        return block.timestamp >= entry.expiry ? address(0) : entry.owner;
    }

    function getSubregistry(string calldata label) external view override returns (address) {
        Entry memory entry = _entries[uint256(keccak256(bytes(label)))];
        return block.timestamp >= entry.expiry ? address(0) : entry.child;
    }
}

/// @notice LOCAL TEST provenance fixture. Real mode uses the pinned official VerifiableFactory.
contract LocalENSFactoryFixture is LocalENSFixtureBase, IENSVerifiableFactory {
    mapping(address proxy => address implementation) private _implementations;
    error NotVerified();

    function setImplementation(address proxy, address implementation) external onlyFixtureOwner {
        _implementations[proxy] = implementation;
    }

    function verifyContract(address proxy) external view override returns (address implementation) {
        implementation = _implementations[proxy];
        if (implementation == address(0)) revert NotVerified();
    }
}

/// @notice LOCAL TEST implementation identity marker; not a usable registry.
contract LocalENSImplementationFixture is LocalENSFixtureBase {}
