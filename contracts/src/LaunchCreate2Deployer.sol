// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @notice Small deployment utility for the unmodified LBPStrategy's required v4 hook address.
/// @dev Initcode includes ALL constructor arguments. No funds, owner, upgrades or post-deploy calls.
contract LaunchCreate2Deployer {
    event Deployed(address indexed deployed, bytes32 indexed salt, bytes32 initCodeHash);

    function deploy(bytes32 salt, bytes calldata initcode) external returns (address deployed) {
        deployed = Create2.deploy(0, salt, initcode);
        emit Deployed(deployed, salt, keccak256(initcode));
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }
}
