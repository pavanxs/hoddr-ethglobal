// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice One configured provider per registry. Zero means the wallet is not enrolled.
/// @dev A launch must aggregate spend across every wallet linked to the returned identity.
interface IIdentityRegistry {
    function identityOf(address beneficiary) external view returns (bytes32);
    function walletCount(bytes32 identity) external view returns (uint256);
    function walletAt(bytes32 identity, uint256 index) external view returns (address);
}
