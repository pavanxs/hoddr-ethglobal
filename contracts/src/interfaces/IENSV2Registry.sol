// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice Minimal ABI of the reviewed ENSv2 PermissionedRegistry family.
/// @dev Pin: ensdomains/contracts-v2@07e55a056f5b6a9c90119f501bdd05714e67dddd.
interface IENSV2Registry {
    struct State {
        uint8 status; // AVAILABLE=0, RESERVED=1, REGISTERED=2.
        uint64 expiry;
        address latestOwner; // Historical after expiry; never sufficient for eligibility.
        uint256 tokenId;
        uint256 resource;
    }

    function getState(uint256 anyId) external view returns (State memory);
    function getOwner(uint256 anyId) external view returns (address);
    function getSubregistry(string calldata label) external view returns (address);
}

interface IENSVerifiableFactory {
    function verifyContract(address proxy) external view returns (address implementation);
}
