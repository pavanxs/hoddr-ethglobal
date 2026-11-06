// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BlockNumberish} from "blocknumberish/src/BlockNumberish.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {MigratorParameters, PoolParameters, LiquidityAllocationBracket} from "liquidity-launcher/src/libraries/MigratorParams.sol";
import {PositionDefinition} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IENSDomainGateFactory} from "./interfaces/IENSDomainGateFactory.sol";
import {IBidLockFactory} from "./interfaces/IBidLockFactory.sol";
import {ILaunchStrategy, ILaunchAuctionFactory, IFinalizedAuction} from "./interfaces/ILaunchStrategy.sol";
import {LaunchConfig, LaunchRecord, AllowancePreview} from "./LaunchpadTypes.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {PhaseCapHook} from "./PhaseCapHook.sol";
import {PhaseCapHookDeployer} from "./PhaseCapHookDeployer.sol";
import {BidLockFactory} from "./BidLockFactory.sol";
import {BidLock} from "./BidLock.sol";
import {LaunchSettlementVault} from "./LaunchSettlementVault.sol";
import {ZeroFeeController} from "./ZeroFeeController.sol";

/// @notice Creates fixed-supply tokens, genuine CCA sales, bid locks and stock v4 LBP migration.
/// @dev Native ETH only. Every token outside the LP reserve is offered in the auction.
/// No owner, admin fee change, arbitrary identity provider or custom gate registration.
contract LaunchpadFactory is BlockNumberish {
    using SafeERC20 for IERC20;

    uint256 public constant MPS = 10_000_000;
    uint256 public constant MAX_PAGE_SIZE = 50;
    // The pinned CCA allows Q96 prices between 2^32 and 2^160. A full-range v4
    // position can need up to 2^32 units of either asset per unit of liquidity.
    uint256 private constant MIN_LP_BUDGET = 1 << 32;

    ILaunchStrategy public immutable strategy;
    IIdentityRegistry public immutable identityRegistry;
    IENSDomainGateFactory public immutable ensGateFactory;
    address public immutable settlementImplementation;
    BidLockFactory public immutable wrapperFactory;
    PhaseCapHookDeployer public immutable hookDeployer;

    uint256 public launchCount;
    mapping(uint256 id => LaunchRecord) private _launches;
    mapping(address creator => mapping(bytes32 userSalt => uint256 id)) public launchForSalt;
    uint256 private _entered;

    error InvalidConfiguration();
    error UnknownENSGate(address gate);
    error InvalidIdentityConfiguration();
    error SaltAlreadyUsed();
    error WrongHookAddress(address predicted);
    error UnknownLaunch();
    error InvalidPage();
    error Reentrancy();
    error AuctionCreationFailed();

    event LaunchCreated(
        uint256 indexed id,
        address indexed creator,
        address indexed token,
        address auction,
        address validationHook,
        address settlement,
        address treasury
    );

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(
        address strategy_,
        address identityRegistry_,
        address ensGateFactory_,
        address settlementImplementation_
    ) {
        if (strategy_.code.length == 0 || settlementImplementation_.code.length == 0) revert InvalidConfiguration();
        if (identityRegistry_ != address(0) && identityRegistry_.code.length == 0) revert InvalidConfiguration();
        if (ensGateFactory_ != address(0) && ensGateFactory_.code.length == 0) revert InvalidConfiguration();
        strategy = ILaunchStrategy(strategy_);
        identityRegistry = IIdentityRegistry(identityRegistry_);
        ensGateFactory = IENSDomainGateFactory(ensGateFactory_);
        settlementImplementation = settlementImplementation_;
        if (address(LaunchSettlementVault(payable(settlementImplementation_)).strategy()) != strategy_) {
            revert InvalidConfiguration();
        }
        address controller = ILaunchAuctionFactory(strategy.initializerFactory()).protocolFeeController();
        if (controller != address(0) && controller.codehash != keccak256(type(ZeroFeeController).runtimeCode)) {
            revert InvalidConfiguration();
        }
        wrapperFactory = new BidLockFactory(address(this));
        hookDeployer = new PhaseCapHookDeployer();
    }

    function launchAt(uint256 id) public view returns (LaunchRecord memory) {
        if (id == 0 || id > launchCount) revert UnknownLaunch();
        return _launches[id];
    }

    /// @notice Ascending IDs starting at 1; request at most 50 records.
    function getLaunches(uint256 startId, uint256 count) external view returns (LaunchRecord[] memory result) {
        if (startId == 0 || count > MAX_PAGE_SIZE) revert InvalidPage();
        uint256 available = startId > launchCount ? 0 : launchCount - startId + 1;
        if (count > available) count = available;
        result = new LaunchRecord[](count);
        for (uint256 i; i < count; ++i) result[i] = _launches[startId + i];
    }

    function predictSettlementAddress(address creator, bytes32 userSalt, bytes32 poolHookSalt)
        public view returns (address)
    {
        return Clones.predictDeterministicAddress(
            settlementImplementation, keccak256(abi.encode(creator, userSalt, poolHookSalt)), address(this)
        );
    }

    /// @notice Standard EIP-1167 creation-code hash for client-side v4 hook-address salt mining.
    function settlementInitCodeHash() external view returns (bytes32) {
        return keccak256(abi.encodePacked(
            hex"3d602d80600a3d3981f3", hex"363d3d373d3d3d363d73",
            settlementImplementation, hex"5af43d82803e903d91602b57fd5bf3"
        ));
    }

    function createLaunch(LaunchConfig calldata config)
        external nonReentrant returns (uint256 id, address token, address auction, address hook, address settlement)
    {
        _validate(config);
        if (launchForSalt[msg.sender][config.userSalt] != 0) revert SaltAlreadyUsed();
        settlement = predictSettlementAddress(msg.sender, config.userSalt, config.poolHookSalt);
        if ((uint160(settlement) & ((1 << 14) - 1)) != (1 << 13)) revert WrongHookAddress(settlement);
        bytes32 creatorSalt = keccak256(abi.encode(msg.sender, config.userSalt));
        token = address(new LaunchToken{salt: creatorSalt}(config.name, config.symbol, config.totalSupply, address(this)));
        hook = address(hookDeployer.deploy(
            address(wrapperFactory),
            config.identityEnabled ? identityRegistry : IIdentityRegistry(address(0)),
            config.phases,
            config.lockOptions
        ));
        address clone = Clones.cloneDeterministic(
            settlementImplementation, keccak256(abi.encode(msg.sender, config.userSalt, config.poolHookSalt))
        );
        if (clone != settlement) revert InvalidConfiguration();
        uint64 endBlock = config.phases[config.phases.length - 1].endBlock;
        LaunchSettlementVault(payable(settlement)).initialize(
            token, config.treasury, config.reserveForLiquidity, config.liquidityAllocationMps,
            config.poolFee, config.poolTickSpacing, endBlock + 1
        );
        auction = _initializeAuction(config, token, hook, settlement, creatorSalt);
        PhaseCapHook(hook).bindAuction(auction);
        LaunchSettlementVault(payable(settlement)).bindAuction(IFinalizedAuction(auction));
        wrapperFactory.registerAuction(auction, hook);
        LaunchToken(token).bindAuction(auction, IBidLockFactory(address(wrapperFactory)));

        id = ++launchCount;
        launchForSalt[msg.sender][config.userSalt] = id;
        LaunchRecord storage record = _launches[id];
        record.id = id;
        record.creator = msg.sender;
        record.token = token;
        record.auction = auction;
        record.validationHook = hook;
        record.settlement = settlement;
        record.treasury = config.treasury;
        record.startBlock = config.phases[0].startBlock;
        record.endBlock = endBlock;
        record.claimBlock = endBlock + 2;
        record.totalSupply = config.totalSupply;
        record.reserveForLiquidity = config.reserveForLiquidity;
        record.floorPriceQ96 = config.floorPriceQ96;
        record.priceTickSpacing = config.priceTickSpacing;
        record.requiredCurrencyRaised = config.requiredCurrencyRaised;
        record.poolFee = config.poolFee;
        record.poolTickSpacing = config.poolTickSpacing;
        record.liquidityAllocationMps = config.liquidityAllocationMps;
        record.identityEnabled = config.identityEnabled;
        record.name = config.name;
        record.symbol = config.symbol;
        record.metadataURI = config.metadataURI;
        emit LaunchCreated(id, msg.sender, token, auction, hook, settlement, config.treasury);
    }

    function previewBid(uint256 id, address beneficiary, uint256 proposedLockOption)
        external view returns (AllowancePreview memory)
    {
        LaunchRecord memory launch = launchAt(id);
        return PhaseCapHook(launch.validationHook).preview(beneficiary, proposedLockOption);
    }

    function createPosition(uint256 id, uint256 lockOption, uint64 minimumUnlockDate)
        external nonReentrant returns (address wrapper)
    {
        LaunchRecord memory launch = launchAt(id);
        wrapper = address(wrapperFactory.createBidLockFor(msg.sender, launch.auction, lockOption, minimumUnlockDate));
    }

    function finalizeLaunch(uint256 id) external returns (LaunchSettlementVault.SettlementStatus) {
        return LaunchSettlementVault(payable(launchAt(id).settlement)).settle();
    }

    function recoverLiquidity(uint256 id) external returns (uint256 positionId) {
        return LaunchSettlementVault(payable(launchAt(id).settlement)).recoverLiquidity();
    }

    /// @notice Uniform per-block issuance, with indivisible millionths added to the final block.
    function auctionSteps(uint64 durationBlocks) public pure returns (bytes memory) {
        if (durationBlocks == 0 || durationBlocks > MPS) revert InvalidConfiguration();
        uint24 rate = uint24(MPS / durationBlocks);
        if (durationBlocks == 1) return abi.encodePacked(rate, uint40(1));
        uint24 lastRate = rate + uint24(MPS % durationBlocks);
        return abi.encodePacked(rate, uint40(durationBlocks - 1), lastRate, uint40(1));
    }

    function _initializeAuction(
        LaunchConfig calldata config,
        address token,
        address hook,
        address settlement,
        bytes32 strategySalt
    ) private returns (address auction) {
        uint64 startBlock = config.phases[0].startBlock;
        uint64 endBlock = config.phases[config.phases.length - 1].endBlock;
        AuctionParameters memory parameters = AuctionParameters({
            currency: address(0),
            tokensRecipient: settlement,
            fundsRecipient: address(strategy),
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: endBlock + 2,
            tickSpacing: config.priceTickSpacing,
            validationHook: hook,
            floorPrice: config.floorPriceQ96,
            requiredCurrencyRaised: config.requiredCurrencyRaised,
            auctionStepsData: auctionSteps(endBlock - startBlock)
        });
        LiquidityAllocationBracket[] memory brackets = new LiquidityAllocationBracket[](1);
        brackets[0] = LiquidityAllocationBracket(0, config.liquidityAllocationMps);
        MigratorParameters memory migration = MigratorParameters({
            token: token,
            currency: address(0),
            migrationBlock: endBlock + 1,
            reservedTokenAmountForLP: config.reserveForLiquidity,
            recipient: settlement,
            positionRecipient: settlement,
            poolParameters: PoolParameters(config.poolFee, config.poolTickSpacing, settlement),
            positionDefinitions: abi.encode(new PositionDefinition[](0)),
            lpAllocationSchedule: abi.encode(brackets)
        });
        bytes memory initializerParams = abi.encode(parameters);
        bytes32 initializerSalt = keccak256(abi.encode(strategySalt, migration));
        auction = ILaunchAuctionFactory(strategy.initializerFactory()).getAddress(
            token, config.totalSupply - config.reserveForLiquidity, initializerParams,
            initializerSalt, address(strategy)
        );
        IERC20(token).forceApprove(address(strategy), config.totalSupply);
        strategy.initializeDistribution(
            token, config.totalSupply, abi.encode(migration, initializerParams), strategySalt
        );
        if (auction.code.length == 0) revert AuctionCreationFailed();
        IERC20(token).forceApprove(address(strategy), 0);
    }

    function _validate(LaunchConfig calldata config) private view {
        if (bytes(config.name).length == 0 || bytes(config.name).length > 64
            || bytes(config.symbol).length == 0 || bytes(config.symbol).length > 16
            || bytes(config.metadataURI).length > 2048 || config.treasury == address(0)
            || config.reserveForLiquidity < MIN_LP_BUDGET
            || config.reserveForLiquidity >= config.totalSupply
            || config.reserveForLiquidity > uint128(type(int128).max)
            || config.totalSupply - config.reserveForLiquidity > (1 << 100)
            || config.requiredCurrencyRaised == 0 || config.floorPriceQ96 < (1 << 32) + 1
            || config.priceTickSpacing < 2 || config.phases.length == 0 || config.phases.length > 16
            || config.liquidityAllocationMps > MPS
            || uint256(config.requiredCurrencyRaised) * config.liquidityAllocationMps < MPS * MIN_LP_BUDGET
            || config.poolFee > 1_000_000) revert InvalidConfiguration();
        uint64 start = config.phases[0].startBlock;
        uint64 end = config.phases[config.phases.length - 1].endBlock;
        if (start <= _getBlockNumberish() || end <= start || end - start > MPS
            || end > type(uint64).max - 2) revert InvalidConfiguration();
        if (config.identityEnabled && address(identityRegistry) == address(0)) revert InvalidIdentityConfiguration();
        for (uint256 i; i < config.phases.length; ++i) {
            if (config.phases[i].verifiedOnly && !config.identityEnabled) revert InvalidIdentityConfiguration();
            address gate = config.phases[i].ensGate;
            if (gate != address(0)
                && (address(ensGateFactory) == address(0) || !ensGateFactory.isGate(gate))) revert UnknownENSGate(gate);
        }
    }
}
