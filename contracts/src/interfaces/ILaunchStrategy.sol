// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";

interface ILaunchStrategy {
    function poolManager() external view returns (IPoolManager);
    function positionManager() external view returns (IPositionManager);
    function initializerFactory() external view returns (address);
    function registeredPoolIds(PoolId poolId) external view returns (address);
    function initializeDistribution(address token, uint256 supply, bytes calldata configuration, bytes32 salt) external;
    function migrate(ILBPInitializer initializer) external;
}

interface ILaunchAuctionFactory {
    function protocolFeeController() external view returns (address);
    function getAddress(address token, uint256 amount, bytes calldata config, bytes32 salt, address sender)
        external view returns (address);
}

interface IFinalizedAuction {
    function token() external view returns (address);
    function currency() external view returns (address);
    function fundsRecipient() external view returns (address);
    function tokensRecipient() external view returns (address);
    function endBlock() external view returns (uint64);
    function sweepCurrencyBlock() external view returns (uint256);
    function sweepUnsoldTokensBlock() external view returns (uint256);
    function checkpoint() external;
    function isGraduated() external view returns (bool);
    function currencyRaised() external view returns (uint256);
    function sweepUnsoldTokens() external;
}
