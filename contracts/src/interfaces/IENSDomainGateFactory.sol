// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IENSDomainGateFactory {
    function create(string[] calldata parentLabels) external returns (address gate);
    function isGate(address gate) external view returns (bool);
    function gateForParent(bytes32 parentNamehash) external view returns (address);
}
