// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {LockOption, AllowancePreview} from "../LaunchpadTypes.sol";

interface IPhaseCapHook {
    function auction() external view returns (address);
    function wrapperFactory() external view returns (address);
    function lockOptionAt(uint256 index) external view returns (LockOption memory);
    function lockOptionCount() external view returns (uint256);
    function preview(address beneficiary, uint256 proposedLockOption) external view returns (AllowancePreview memory);
}
