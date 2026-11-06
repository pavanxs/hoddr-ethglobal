// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice Quote budgets are native ETH wei. Phase windows are [startBlock, endBlock).
struct PhaseConfig {
    uint64 startBlock;
    uint64 endBlock;
    uint128 baseCapStart;
    uint128 baseCapEnd;
    uint128 verifiedCapStart;
    uint128 verifiedCapEnd;
    uint128 minimumBid;
    bool verifiedOnly;
    address ensGate;
}

/// @notice The multiplier rewards a minimum holding duration after the first actual CCA token payout.
struct LockOption {
    uint64 durationSeconds;
    uint32 multiplierBps;
}

struct AllowancePreview {
    uint256 phaseIndex;
    uint256 currentBlock;
    address wrapper;
    bytes32 identity;
    bool active;
    bool verified;
    bool identityRequired;
    bool ensRequired;
    bool identityAllowed;
    uint256 accountCommitted;
    uint256 committed;
    uint256 cap;
    uint256 remaining;
    uint256 minimumBid;
    uint256 effectiveLockOptionIndex;
    uint32 effectiveMultiplierBps;
}

/// @notice Immutable creation settings. This version only quotes sales in native ETH.
struct LaunchConfig {
    string name;
    string symbol;
    string metadataURI;
    uint128 totalSupply;
    uint128 reserveForLiquidity;
    uint256 floorPriceQ96;
    uint256 priceTickSpacing;
    uint128 requiredCurrencyRaised;
    uint24 poolFee;
    int24 poolTickSpacing;
    uint24 liquidityAllocationMps;
    address treasury;
    bool identityEnabled;
    PhaseConfig[] phases;
    LockOption[] lockOptions;
    bytes32 userSalt;
    bytes32 poolHookSalt;
}

struct LaunchRecord {
    uint256 id;
    address creator;
    address token;
    address auction;
    address validationHook;
    address settlement;
    address treasury;
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint128 totalSupply;
    uint128 reserveForLiquidity;
    uint256 floorPriceQ96;
    uint256 priceTickSpacing;
    uint128 requiredCurrencyRaised;
    uint24 poolFee;
    int24 poolTickSpacing;
    uint24 liquidityAllocationMps;
    bool identityEnabled;
    string name;
    string symbol;
    string metadataURI;
}
