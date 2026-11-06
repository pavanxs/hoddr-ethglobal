// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PhaseCapHook} from "./PhaseCapHook.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {PhaseConfig, LockOption} from "./LaunchpadTypes.sol";

/// @notice Keeps the per-launch hook's creation bytecode out of the main factory's runtime.
contract PhaseCapHookDeployer {
    function deploy(
        address wrapperFactory,
        IIdentityRegistry identityRegistry,
        PhaseConfig[] calldata phases,
        LockOption[] calldata lockOptions
    ) external returns (PhaseCapHook hook) {
        hook = new PhaseCapHook(msg.sender, wrapperFactory, identityRegistry, phases, lockOptions);
    }
}
