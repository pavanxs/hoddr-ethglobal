// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice The gate's immutable policy identifies the required ENS parent.
interface IENSDomainGate {
    /// @param beneficiary The authenticated participant, not the auction or lock wrapper.
    /// @param evidence abi.encode(string[] labels), nearest parent first.
    ///        ["team", "alice"] means alice.team.<configured-parent>.
    function isEligible(address beneficiary, bytes calldata evidence) external view returns (bool);
}
