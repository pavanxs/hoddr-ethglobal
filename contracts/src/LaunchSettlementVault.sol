// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BlockNumberish} from "blocknumberish/src/BlockNumberish.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IInitializerHook} from "liquidity-launcher/src/interfaces/IInitializerHook.sol";
import {ILBPInitializer, LBPInitializationParams} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {Plan, Position, PositionDefinition, CurrencyAmounts} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {ILaunchStrategy, ILaunchAuctionFactory, IFinalizedAuction} from "./interfaces/ILaunchStrategy.sol";
import {ZeroFeeController} from "./ZeroFeeController.sol";

/// @notice Holds sale proceeds until the exact v4 pool has a real, owned liquidity position.
/// @dev Stock LBPStrategy catches failed migrations and force-sends funds to its recipient.
/// This recipient keeps that fallback in escrow. A permissionless retry uses the SAME final
/// CCA price, reserve, allocation and upstream PositionPlanner. No administrator can change them.
/// Each EIP-1167 clone is also the pool's beforeInitialize-only hook. It has no swap restrictions.
contract LaunchSettlementVault is IInitializerHook, BlockNumberish {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    enum SettlementStatus { Pending, Ready, RecoveryNeeded, Succeeded, FailedGraduation }

    uint256 public constant MPS = 10_000_000;
    uint160 public constant HOOK_FLAGS = 1 << 13;
    uint160 public constant HOOK_MASK = (1 << 14) - 1;

    ILaunchStrategy public immutable strategy;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    address public factory;
    IERC20 public token;
    IFinalizedAuction public auction;
    address public treasury;
    uint128 public reserveForLiquidity;
    uint24 public liquidityAllocationMps;
    uint24 public poolFee;
    int24 public poolTickSpacing;
    uint64 public migrationBlock;

    uint256 public positionId;
    bool public recovered;
    bool public positionReleased;
    bool private _succeeded;
    bool private _settling;
    bool private _recovering;
    uint256 private _entered;

    error Unauthorized();
    error AlreadyInitialized();
    error InvalidConfiguration();
    error AuctionMismatch();
    error AuctionNotBound();
    error WrongHookAddress();
    error InitializationNotAuthorized();
    error InvalidPoolKey();
    error TooEarly();
    error Reentrancy();
    error RecoveryNotAvailable();
    error EscrowIncomplete();
    error NoLiquidityBudget();
    error UnexpectedPoolState();
    error SettlementProofFailed();
    error TreasuryReleaseBlocked();
    error PositionAlreadyReleased();
    error NativeTransferFailed();
    error InvalidRecipient();

    event AuctionBound(address indexed auction);
    event SettlementCompleted(address indexed auction, bytes32 indexed poolId, uint256 indexed positionId, bool recovered);
    event SettlementObserved(SettlementStatus status);
    event TreasuryProceedsReleased(address indexed recipient, uint256 currencyAmount, uint256 tokenAmount);
    event PositionReleased(address indexed recipient, uint256 indexed positionId);

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }
    modifier onlyTreasury() {
        if (msg.sender != treasury) revert Unauthorized();
        _;
    }

    constructor(ILaunchStrategy strategy_) {
        if (address(strategy_).code.length == 0) revert InvalidConfiguration();
        address initializerFactory = strategy_.initializerFactory();
        address controller = ILaunchAuctionFactory(initializerFactory).protocolFeeController();
        // Stock CCA permanently disables protocol fees when its immutable controller is zero.
        if (controller != address(0) && controller.codehash != keccak256(type(ZeroFeeController).runtimeCode)) {
            revert InvalidConfiguration();
        }
        strategy = strategy_;
        poolManager = strategy_.poolManager();
        positionManager = strategy_.positionManager();
        if (address(poolManager).code.length == 0 || address(positionManager).code.length == 0) {
            revert InvalidConfiguration();
        }
        // The shared implementation is never itself a live vault. Clones have zero storage.
        factory = address(1);
    }

    receive() external payable {}

    function initialize(
        address token_,
        address treasury_,
        uint128 reserve_,
        uint24 allocation_,
        uint24 fee_,
        int24 tickSpacing_,
        uint64 migrationBlock_
    ) external {
        if (factory != address(0)) revert AlreadyInitialized();
        if (uint160(address(this)) & HOOK_MASK != HOOK_FLAGS) revert WrongHookAddress();
        if (token_.code.length == 0 || treasury_ == address(0) || reserve_ == 0
            || reserve_ > uint128(type(int128).max) || allocation_ == 0 || allocation_ > MPS
            || fee_ > 1_000_000 || tickSpacing_ < TickMath.MIN_TICK_SPACING
            || tickSpacing_ > TickMath.MAX_TICK_SPACING || migrationBlock_ == 0) {
            revert InvalidConfiguration();
        }
        factory = msg.sender;
        token = IERC20(token_);
        treasury = treasury_;
        reserveForLiquidity = reserve_;
        liquidityAllocationMps = allocation_;
        poolFee = fee_;
        poolTickSpacing = tickSpacing_;
        migrationBlock = migrationBlock_;
    }

    function bindAuction(IFinalizedAuction auction_) external {
        if (msg.sender != factory) revert Unauthorized();
        if (address(auction) != address(0)) revert AlreadyInitialized();
        if (address(auction_).code.length == 0 || auction_.token() != address(token)
            || auction_.currency() != address(0) || auction_.fundsRecipient() != address(strategy)
            || auction_.tokensRecipient() != address(this) || auction_.endBlock() >= migrationBlock) {
            revert AuctionMismatch();
        }
        auction = auction_;
        emit AuctionBound(address(auction_));
    }

    function authorized() external view returns (address) { return address(strategy); }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function poolId() public view returns (bytes32) { return PoolId.unwrap(poolKey().toId()); }

    /// @notice The exact pool can only initialize while this vault is executing its bound migration.
    /// Direct calls to stock migrate are safely recovered into escrow rather than releasing proceeds.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager) || address(auction) == address(0)) {
            revert InitializationNotAuthorized();
        }
        if (!((_settling && sender == address(strategy)) || (_recovering && sender == address(this)))) {
            revert InitializationNotAuthorized();
        }
        if (PoolId.unwrap(key.toId()) != poolId()) revert InvalidPoolKey();
        return IHooks.beforeInitialize.selector;
    }

    function status() public view returns (SettlementStatus) {
        if (_succeeded) return SettlementStatus.Succeeded;
        if (address(auction) == address(0)) return SettlementStatus.Pending;
        if (auction.sweepCurrencyBlock() != 0) {
            return auction.isGraduated() ? SettlementStatus.RecoveryNeeded : SettlementStatus.FailedGraduation;
        }
        return _getBlockNumberish() < migrationBlock ? SettlementStatus.Pending : SettlementStatus.Ready;
    }

    function poolState()
        external view returns (uint160 sqrtPriceX96, uint128 activeLiquidity, uint128 ownedPositionLiquidity)
    {
        PoolId id = poolKey().toId();
        (sqrtPriceX96,,,) = poolManager.getSlot0(id);
        activeLiquidity = poolManager.getLiquidity(id);
        if (positionId != 0 && !positionReleased) ownedPositionLiquidity = positionManager.getPositionLiquidity(positionId);
    }

    /// @notice Anyone may finish an ended sale. Identity/name eligibility is only for new bids.
    function settle() external nonReentrant returns (SettlementStatus result) {
        _requireMature();
        if (_succeeded) return SettlementStatus.Succeeded;
        if (auction.sweepCurrencyBlock() == 0) {
            auction.checkpoint();
            uint256 candidate = positionManager.nextTokenId();
            _settling = true;
            strategy.migrate(ILBPInitializer(address(auction)));
            _settling = false;
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey().toId());
            if (sqrtPriceX96 != 0) {
                _recordSuccess(candidate, false);
            }
        }
        _collectUnsold();
        result = status();
        emit SettlementObserved(result);
    }

    /// @notice Retry a stock migration whose caught failure has already put its full budget here.
    /// Uses genuine finalized CCA state. Donations alone can never activate this route.
    function recoverLiquidity() external nonReentrant returns (uint256 mintedPositionId) {
        _requireMature();
        if (status() != SettlementStatus.RecoveryNeeded) revert RecoveryNotAvailable();
        LBPInitializationParams memory lbp = ILBPInitializer(address(auction)).lbpInitializationParams();
        // The pinned immutable zero-fee controller makes this amount stable across retry dates.
        if (lbp.currencyRaised != auction.currencyRaised()) revert EscrowIncomplete();
        if (address(this).balance < lbp.currencyRaised || token.balanceOf(address(this)) < reserveForLiquidity) {
            revert EscrowIncomplete();
        }
        uint256 currencyBudget = FullMath.mulDiv(lbp.currencyRaised, liquidityAllocationMps, MPS);
        if (currencyBudget > uint128(type(int128).max)) currencyBudget = uint128(type(int128).max);
        if (currencyBudget == 0) revert NoLiquidityBudget();

        PoolKey memory key = poolKey();
        (uint160 existingPrice,,,) = poolManager.getSlot0(key.toId());
        // Both upstream tryMigrate and this retry are atomic: a failed mint also rolls pool
        // initialization back. A pre-existing pool without a recorded success is unexpected.
        if (existingPrice != 0) revert UnexpectedPoolState();
        uint160 sqrtPriceX96 =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(lbp.initialPriceX96, true));
        (Position[] memory positions, CurrencyAmounts memory unused) = PositionPlanner.resolve(
            new PositionDefinition[](0),
            sqrtPriceX96,
            poolTickSpacing,
            CurrencyAmounts(currencyBudget, reserveForLiquidity),
            address(this)
        );
        if (positions.length != 1 || positions[0].liquidity == 0) revert NoLiquidityBudget();
        uint256 currencyUsed = currencyBudget - unused.amount0;
        uint256 tokenUsed = reserveForLiquidity - unused.amount1;
        Plan memory plan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);
        mintedPositionId = positionManager.nextTokenId();

        _recovering = true;
        poolManager.initialize(key, sqrtPriceX96);
        _recovering = false;
        token.safeTransfer(address(positionManager), tokenUsed);
        positionManager.modifyLiquidities{value: currencyUsed}(abi.encode(plan.actions, plan.params), block.timestamp);
        _recordSuccess(mintedPositionId, true);
        _collectUnsold();
    }

    function collectUnsoldTokens() external nonReentrant {
        _requireMature();
        _collectUnsold();
    }

    /// @notice Releases unused sale/LP tokens and non-LP ETH after proven settlement.
    /// Failed graduation has no raised proceeds: CCA still holds bidders' full refund balances.
    function releaseProceeds(address payable recipient) external onlyTreasury nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        SettlementStatus state = status();
        if (state != SettlementStatus.Succeeded && state != SettlementStatus.FailedGraduation) {
            revert TreasuryReleaseBlocked();
        }
        _collectUnsold();
        uint256 tokenAmount = token.balanceOf(address(this));
        uint256 currencyAmount = address(this).balance;
        if (tokenAmount != 0) token.safeTransfer(recipient, tokenAmount);
        if (currencyAmount != 0) {
            (bool ok,) = recipient.call{value: currencyAmount}("");
            if (!ok) revert NativeTransferFailed();
        }
        emit TreasuryProceedsReleased(recipient, currencyAmount, tokenAmount);
    }

    /// @notice LP ownership is transferable to the configured treasury after successful creation.
    /// This is NOT an LP lock; the bid wrappers separately lock participants' purchased tokens.
    function releasePosition(address recipient) external onlyTreasury nonReentrant {
        if (!_succeeded) revert TreasuryReleaseBlocked();
        if (positionReleased) revert PositionAlreadyReleased();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        positionReleased = true;
        IERC721(address(positionManager)).transferFrom(address(this), recipient, positionId);
        emit PositionReleased(recipient, positionId);
    }

    function _requireMature() private view {
        if (address(auction) == address(0)) revert AuctionNotBound();
        if (_getBlockNumberish() < migrationBlock) revert TooEarly();
    }

    function _collectUnsold() private {
        if (auction.sweepUnsoldTokensBlock() == 0) auction.sweepUnsoldTokens();
    }

    function _recordSuccess(uint256 candidate, bool wasRecovery) private {
        if (positionManager.nextTokenId() != candidate + 1 || IERC721(address(positionManager)).ownerOf(candidate) != address(this)) {
            revert SettlementProofFailed();
        }
        (PoolKey memory actualKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(candidate);
        PoolKey memory expectedKey = poolKey();
        if (PoolId.unwrap(actualKey.toId()) != PoolId.unwrap(expectedKey.toId())
            || info.tickLower() != TickMath.minUsableTick(poolTickSpacing)
            || info.tickUpper() != TickMath.maxUsableTick(poolTickSpacing)
            || positionManager.getPositionLiquidity(candidate) == 0
            || poolManager.getLiquidity(expectedKey.toId()) == 0) revert SettlementProofFailed();
        positionId = candidate;
        recovered = wasRecovery;
        _succeeded = true;
        emit SettlementCompleted(address(auction), PoolId.unwrap(expectedKey.toId()), candidate, wasRecovery);
    }
}
