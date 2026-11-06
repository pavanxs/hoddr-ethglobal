// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {StepLib} from "continuous-clearing-auction/libraries/StepLib.sol";
import {ValidationHookLib} from "continuous-clearing-auction/libraries/ValidationHookLib.sol";
import {LBPStrategy} from "liquidity-launcher/src/strategies/lbp/LBPStrategy.sol";
import {ILBPStrategy} from "liquidity-launcher/src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IDistributorFactory} from "liquidity-launcher/src/interfaces/IDistributorFactory.sol";
import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {Position, PositionDefinition, CurrencyAmounts} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";
import {LaunchSettlementVault} from "../src/LaunchSettlementVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BidLock} from "../src/BidLock.sol";
import {PhaseCapHook} from "../src/PhaseCapHook.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ENSDomainGate} from "../src/ENSDomainGate.sol";
import {ENSDomainGateFactory} from "../src/ENSDomainGateFactory.sol";
import {LocalWorldIDFixture} from "./mocks/LocalWorldIDFixture.sol";
import {LocalENSRegistryFixture, LocalENSFactoryFixture, LocalENSImplementationFixture} from "./mocks/LocalENSFixtures.sol";
import {ZeroFeeController} from "../src/ZeroFeeController.sol";
import {LaunchCreate2Deployer} from "../src/LaunchCreate2Deployer.sol";
import {ILaunchStrategy, IFinalizedAuction} from "../src/interfaces/ILaunchStrategy.sol";
import {IBidLockFactory} from "../src/interfaces/IBidLockFactory.sol";
import {LaunchConfig, LaunchRecord, PhaseConfig, LockOption} from "../src/LaunchpadTypes.sol";

/// @notice These tests deploy the pinned ORIGINAL CCA, LBPStrategy, PoolManager and PositionManager.
/// The gated-sale test uses local World ID and ENS fixtures for the external provider state.
/// Permit2/WETH/descriptor are explicitly disabled because the launch only uses prepaid native LP minting.
contract LaunchpadIntegrationTest is Test {
    using StepLib for bytes;

    uint256 constant Q96 = 1 << 96;
    uint64 constant START = 100;
    uint64 constant END = 200;
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address stranger = address(0xB0B);
    address treasury = address(0xCAFE);

    IPoolManager poolManager;
    IPositionManager positionManager;
    ContinuousClearingAuctionFactory ccaFactory;
    LBPStrategy strategy;
    ZeroFeeController fees;
    LaunchSettlementVault implementation;
    LaunchpadFactory factory;

    uint256 launchId;
    LaunchToken token;
    IContinuousClearingAuction auction;
    PhaseCapHook capHook;
    LaunchSettlementVault vault;
    BidLock wrapper;

    function setUp() public {
        vm.chainId(31337);
        vm.roll(1);
        vm.warp(1_800_000_000);
        vm.deal(alice, 100 ether);
        vm.deal(stranger, 100 ether);
        fees = ZeroFeeController(payable(_deploy("ZeroFeeController.sol:ZeroFeeController", "")));
        poolManager = IPoolManager(_deploy("PoolManager.sol:PoolManager", abi.encode(address(this))));
        positionManager = IPositionManager(_deploy(
            "PositionManager.sol:PositionManager",
            abi.encode(poolManager, IAllowanceTransfer(address(0)), uint256(100_000), IPositionDescriptor(address(0)), IWETH9(address(0)))
        ));
        _configureLauncher(address(fees));
    }

    function _configureLauncher(address controller) internal {
        ccaFactory = ContinuousClearingAuctionFactory(_deploy(
            "ContinuousClearingAuctionFactory.sol:ContinuousClearingAuctionFactory", abi.encode(controller)
        ));
        strategy = _deployStrategy();
        implementation = LaunchSettlementVault(payable(_deploy(
            "LaunchSettlementVault.sol:LaunchSettlementVault", abi.encode(ILaunchStrategy(address(strategy)))
        )));
        factory = LaunchpadFactory(_deploy(
            "LaunchpadFactory.sol:LaunchpadFactory", abi.encode(address(strategy), address(0), address(0), address(implementation))
        ));
    }

    function _deploy(string memory artifact, bytes memory arguments) internal returns (address deployed) {
        bytes memory creation = abi.encodePacked(vm.getCode(artifact), arguments);
        assertLe(creation.length, 49_152, string.concat("initcode limit: ", artifact));
        assembly ("memory-safe") { deployed := create(0, add(creation, 0x20), mload(creation)) }
        assertTrue(deployed != address(0), string.concat("deployment failed: ", artifact));
        assertLe(deployed.code.length, 24_576, string.concat("runtime limit: ", artifact));
    }

    function _deployStrategy() internal returns (LBPStrategy deployed) {
        LaunchCreate2Deployer deployer = new LaunchCreate2Deployer();
        bytes memory initcode = abi.encodePacked(
            vm.getCode("LBPStrategy.sol:LBPStrategy"),
            abi.encode(positionManager, poolManager, IDistributorFactory(address(ccaFactory)))
        );
        assertLe(initcode.length, 49_152);
        bytes32 initHash = keccak256(initcode);
        for (uint256 i; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff), address(deployer), salt, initHash
            )))));
            if (uint160(predicted) & ((1 << 14) - 1) == 1 << 13) {
                deployed = LBPStrategy(payable(deployer.deploy(salt, initcode)));
                assertEq(address(deployed), predicted);
                assertLe(address(deployed).code.length, 24_576);
                return deployed;
            }
        }
        revert("no strategy hook salt");
    }

    function _config(bool failedGraduation) internal view returns (LaunchConfig memory c) {
        c.name = "Local CCA Token";
        c.symbol = "LCCA";
        c.metadataURI = "ipfs://local-test-metadata";
        c.totalSupply = 1000 ether;
        c.reserveForLiquidity = 200 ether;
        c.floorPriceQ96 = Q96 / 1000;
        c.priceTickSpacing = c.floorPriceQ96 / 10;
        c.requiredCurrencyRaised = failedGraduation ? 100 ether : 0.1 ether;
        c.poolFee = 3000;
        c.poolTickSpacing = 60;
        c.liquidityAllocationMps = 5_000_000;
        c.treasury = treasury;
        c.identityEnabled = false;
        c.phases = new PhaseConfig[](2);
        c.phases[0] = PhaseConfig(START, 150, 10 ether, 10 ether, 20 ether, 20 ether, 0.01 ether, false, address(0));
        c.phases[1] = PhaseConfig(150, END, 10 ether, 20 ether, 20 ether, 40 ether, 0.01 ether, false, address(0));
        c.lockOptions = new LockOption[](2);
        c.lockOptions[0] = LockOption(0, 10_000);
        c.lockOptions[1] = LockOption(30 days, 15_000);
        c.userSalt = keccak256("real-CCA-v4-fixture");
        c.poolHookSalt = _mineSalt(creator, c.userSalt);
    }

    function _mineSalt(address launchCreator, bytes32 userSalt) internal view returns (bytes32 salt) {
        bytes32 initHash = factory.settlementInitCodeHash();
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            bytes32 scoped = keccak256(abi.encode(launchCreator, userSalt, salt));
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), scoped, initHash)))));
            if (uint160(predicted) & ((1 << 14) - 1) == 1 << 13) return salt;
        }
        revert("no hook salt");
    }

    function _create(bool failedGraduation, uint256 lockOption) internal {
        _createConfigured(_config(failedGraduation), lockOption);
    }

    function _createConfigured(LaunchConfig memory c, uint256 lockOption) internal {
        address predicted = factory.predictSettlementAddress(creator, c.userSalt, c.poolHookSalt);
        vm.prank(creator);
        (uint256 id, address t, address a, address h, address s) = factory.createLaunch(c);
        launchId = id;
        token = LaunchToken(t);
        auction = IContinuousClearingAuction(a);
        capHook = PhaseCapHook(h);
        vault = LaunchSettlementVault(payable(s));
        assertEq(s, predicted);
        assertEq(uint160(s) & ((1 << 14) - 1), 1 << 13);
        vm.prank(alice);
        wrapper = BidLock(payable(factory.createPosition(id, lockOption, 0)));
    }

    function _bid(uint128 amount) internal returns (uint256 id) {
        vm.roll(START);
        LaunchRecord memory launch = factory.launchAt(launchId);
        vm.prank(alice);
        id = wrapper.bid{value: amount}(
            launch.floorPriceQ96 + 1000 * launch.priceTickSpacing,
            amount,
            launch.floorPriceQ96,
            ""
        );
    }

    function _finishAuction() internal {
        vm.roll(END + 2);
        auction.checkpoint();
    }

    function _communityGate() internal returns (
        ENSDomainGateFactory gates, LocalENSRegistryFixture community, address gate
    ) {
        LocalENSRegistryFixture root = new LocalENSRegistryFixture();
        LocalENSRegistryFixture eth = new LocalENSRegistryFixture();
        community = new LocalENSRegistryFixture();
        LocalENSFactoryFixture provenance = new LocalENSFactoryFixture();
        LocalENSImplementationFixture impl = new LocalENSImplementationFixture();
        provenance.setImplementation(address(community), address(impl));
        root.setName("eth", creator, type(uint64).max, address(eth));
        eth.setName("community", creator, type(uint64).max, address(community));
        ENSDomainGate.TrustConfig memory config = ENSDomainGate.TrustConfig(
            address(root), address(eth), address(provenance), address(impl),
            address(root).codehash, address(eth).codehash, address(provenance).codehash, address(impl).codehash, true
        );
        gates = ENSDomainGateFactory(_deploy("ENSDomainGateFactory.sol:ENSDomainGateFactory", abi.encode(config)));
        string[] memory parent = new string[](2);
        parent[0] = "eth";
        parent[1] = "community";
        gate = gates.create(parent);
    }

    function testGatedAuctionChecksBothCredentialsAndLetsFormerMembersCollect() public {
        LocalWorldIDFixture router = new LocalWorldIDFixture();
        IdentityRegistry identities = new IdentityRegistry(address(router), "app_local", "launchpad", true);
        (ENSDomainGateFactory gates, LocalENSRegistryFixture community, address gate) = _communityGate();
        factory = LaunchpadFactory(_deploy("LaunchpadFactory.sol:LaunchpadFactory",
            abi.encode(address(strategy), address(identities), address(gates), address(implementation))));
        LaunchConfig memory c = _config(false);
        c.identityEnabled = true;
        c.phases[0].verifiedOnly = true;
        c.phases[0].ensGate = gate;
        _createConfigured(c, 0);
        uint256 price = c.floorPriceQ96 + 1000 * c.priceTickSpacing;
        string[] memory labels = new string[](1);
        labels[0] = "alice";
        bytes memory evidence = abi.encode(labels);
        vm.roll(START);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ValidationHookLib.ValidationHookCallFailed.selector,
            abi.encodeWithSelector(PhaseCapHook.HumanVerificationRequired.selector)));
        wrapper.bid{value: 1 ether}(price, 1 ether, c.floorPriceQ96, evidence);
        uint256[8] memory proof;
        router.allowFixture(1, identities.expectedSignalHash(alice), 7, identities.externalNullifierHash(), proof);
        vm.prank(alice);
        identities.verifyAndBind(alice, 1, 7, proof);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ValidationHookLib.ValidationHookCallFailed.selector,
            abi.encodeWithSelector(PhaseCapHook.ENSNameRequired.selector)));
        wrapper.bid{value: 1 ether}(price, 1 ether, c.floorPriceQ96, evidence);
        assertEq(capHook.accountCommitted(alice, 0), 0);

        community.setName("alice", alice, type(uint64).max, address(0));
        vm.prank(alice);
        uint256 id = wrapper.bid{value: 1 ether}(price, 1 ether, c.floorPriceQ96, evidence);
        assertEq(capHook.accountCommitted(alice, 0), 1 ether);
        community.transferName("alice", stranger);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ValidationHookLib.ValidationHookCallFailed.selector,
            abi.encodeWithSelector(PhaseCapHook.ENSNameRequired.selector)));
        wrapper.bid{value: 1 ether}(price, 1 ether, c.floorPriceQ96, evidence);

        _finishAuction();
        factory.finalizeLaunch(launchId);
        assertEq(uint256(vault.status()), uint256(LaunchSettlementVault.SettlementStatus.Succeeded));
        wrapper.exitBid(id);
        wrapper.claimBid(id);
        vm.prank(alice);
        assertGt(wrapper.withdrawTokens(alice), 0);
    }

    function testRealAuctionMigrationAndPurchasedTokenLock() public {
        _assertMigrationAndPurchasedTokenLock();
    }

    function testZeroControllerSupportsStockMigrationAndPurchasedTokenLock() public {
        _configureLauncher(address(0));
        _assertMigrationAndPurchasedTokenLock();
    }

    function _assertMigrationAndPurchasedTokenLock() internal {
        _create(false, 1);
        uint256 bidId = _bid(1 ether);
        assertEq(token.balanceOf(address(auction)), 800 ether);
        assertEq(token.balanceOf(address(strategy)), 200 ether);
        assertEq(auction.bids(bidId).owner, address(wrapper));
        vm.expectRevert(LaunchSettlementVault.TooEarly.selector);
        factory.finalizeLaunch(launchId);
        _finishAuction();
        assertTrue(auction.isGraduated());

        assertEq(uint256(factory.finalizeLaunch(launchId)), uint256(LaunchSettlementVault.SettlementStatus.Succeeded));
        (uint160 sqrtPrice, uint128 poolLiquidity, uint128 positionLiquidity) = vault.poolState();
        assertGt(sqrtPrice, 0);
        assertGt(poolLiquidity, 0);
        assertGt(positionLiquidity, 0);
        assertEq(IERC721(address(positionManager)).ownerOf(vault.positionId()), address(vault));
        assertFalse(vault.recovered());
        assertEq(strategy.registeredPoolIds(PoolId.wrap(vault.poolId())), address(0));
        assertGt(IFinalizedAuction(address(auction)).sweepCurrencyBlock(), 0);
        assertEq(uint256(factory.finalizeLaunch(launchId)), uint256(LaunchSettlementVault.SettlementStatus.Succeeded));

        // A stranger calls upstream directly. LaunchToken still starts the wrapper's real clock.
        auction.exitBid(bidId);
        assertGt(auction.bids(bidId).tokensFilled, 0);
        vm.prank(stranger);
        auction.claimTokens(bidId);
        assertGt(wrapper.purchasedReceived(), 0);
        assertEq(wrapper.firstClaimTime(), block.timestamp);
        assertEq(wrapper.unlockAt(), block.timestamp + 30 days);
        assertEq(token.balanceOf(address(wrapper)), wrapper.purchasedReceived());
        uint256 expectedUnlock = wrapper.unlockAt();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BidLock.TokensStillLocked.selector, expectedUnlock));
        wrapper.withdrawTokens(alice);

        uint256 refund = address(wrapper).balance;
        if (refund != 0) {
            uint256 beforeBalance = alice.balance;
            vm.prank(alice);
            wrapper.withdrawRefunds(payable(alice));
            assertEq(alice.balance - beforeBalance, refund);
        }
        assertEq(capHook.accountCommitted(alice, 0), 1 ether);
        vm.warp(wrapper.unlockAt());
        vm.prank(alice);
        uint256 received = wrapper.withdrawTokens(alice);
        assertGt(received, 0);
        assertEq(token.balanceOf(alice), received);
        assertEq(wrapper.purchasedOutstanding(), 0);
    }

    function testDirectUpstreamMigrateEscrowsThenRealRecoveryCreatesPool() public {
        _assertDirectMigrationRecovery();
    }

    function testZeroControllerSupportsEscrowAndActualPoolRecovery() public {
        _configureLauncher(address(0));
        _assertDirectMigrationRecovery();
    }

    function _assertDirectMigrationRecovery() internal {
        _create(false, 0);
        uint256 bidId = _bid(1 ether);
        _finishAuction();
        assertTrue(auction.isGraduated());
        uint256 raised = auction.currencyRaised();
        vm.prank(stranger);
        strategy.migrate(ILBPInitializer(address(auction)));

        assertEq(uint256(vault.status()), uint256(LaunchSettlementVault.SettlementStatus.RecoveryNeeded));
        (uint160 sqrtPrice, uint128 liquidity,) = vault.poolState();
        assertEq(sqrtPrice, 0);
        assertEq(liquidity, 0);
        assertEq(address(vault).balance, raised);
        assertEq(token.balanceOf(address(vault)), 200 ether);
        assertEq(treasury.balance, 0);
        vm.prank(treasury);
        vm.expectRevert(LaunchSettlementVault.TreasuryReleaseBlocked.selector);
        vault.releaseProceeds(payable(treasury));

        // Bidders' exits/refunds/claims are independent of the recovery process.
        auction.exitBid(bidId);
        auction.claimTokens(bidId);
        assertGt(wrapper.purchasedReceived(), 0);
        assertEq(uint256(factory.finalizeLaunch(launchId)), uint256(LaunchSettlementVault.SettlementStatus.RecoveryNeeded));
        uint256 position = factory.recoverLiquidity(launchId);
        assertEq(position, vault.positionId());
        assertTrue(vault.recovered());
        assertEq(uint256(vault.status()), uint256(LaunchSettlementVault.SettlementStatus.Succeeded));
        (sqrtPrice, liquidity,) = vault.poolState();
        assertGt(sqrtPrice, 0);
        assertGt(liquidity, 0);
        vm.expectRevert(LaunchSettlementVault.RecoveryNotAvailable.selector);
        factory.recoverLiquidity(launchId);
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InitializerNotRegistered.selector, address(auction)));
        strategy.migrate(ILBPInitializer(address(auction)));
    }

    function testUnsuccessfulGraduationRefundsWithoutEligibilityAndReturnsUnsoldSupply() public {
        _create(true, 1);
        uint256 bidId = _bid(1 ether);
        _finishAuction();
        assertFalse(auction.isGraduated());
        assertEq(uint256(factory.finalizeLaunch(launchId)), uint256(LaunchSettlementVault.SettlementStatus.FailedGraduation));
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 1000 ether);
        assertEq(address(auction).balance, 1 ether);

        vm.prank(stranger);
        wrapper.exitBid(bidId);
        assertEq(address(wrapper).balance, 1 ether);
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        wrapper.withdrawRefunds(payable(alice));
        assertEq(alice.balance, beforeBalance + 1 ether);
        assertEq(wrapper.purchasedReceived(), 0);
        assertEq(wrapper.firstClaimTime(), 0);
        assertEq(capHook.accountCommitted(alice, 0), 1 ether);

        vm.prank(treasury);
        vault.releaseProceeds(payable(treasury));
        assertEq(token.balanceOf(treasury), 1000 ether);
        assertEq(vault.positionId(), 0);
        vm.expectRevert(LaunchSettlementVault.RecoveryNotAvailable.selector);
        vault.recoverLiquidity();
    }

    function testDonatedBalancesCannotPretendMigrationAlreadyHappened() public {
        _create(false, 0);
        uint256 bidId = _bid(1 ether);
        _finishAuction();
        auction.exitBid(bidId);
        auction.claimTokens(bidId);
        vm.prank(alice);
        wrapper.withdrawTokens(alice);
        uint256 donation = token.balanceOf(alice) / 10;
        assertGt(donation, 0);
        vm.startPrank(alice);
        token.transfer(address(vault), donation);
        (bool ok,) = address(vault).call{value: 2 ether}("");
        vm.stopPrank();
        assertTrue(ok);
        assertEq(uint256(vault.status()), uint256(LaunchSettlementVault.SettlementStatus.Ready));
        assertEq(IFinalizedAuction(address(auction)).sweepCurrencyBlock(), 0);
        vm.expectRevert(LaunchSettlementVault.RecoveryNotAvailable.selector);
        vault.recoverLiquidity();
        vm.prank(treasury);
        vm.expectRevert(LaunchSettlementVault.TreasuryReleaseBlocked.selector);
        vault.releaseProceeds(payable(treasury));
        factory.finalizeLaunch(launchId);
        assertEq(uint256(vault.status()), uint256(LaunchSettlementVault.SettlementStatus.Succeeded));
        assertGe(token.balanceOf(address(vault)), donation);
        assertGe(address(vault).balance, 2 ether);
    }

    function testPoolInitializationCannotBeFrontRun() public {
        _create(false, 0);
        PoolKey memory key = vault.poolKey();
        vm.prank(stranger);
        vm.expectRevert();
        poolManager.initialize(key, uint160(Q96));
        (uint160 sqrtPrice, uint128 liquidity,) = vault.poolState();
        assertEq(sqrtPrice, 0);
        assertEq(liquidity, 0);
        vm.prank(address(poolManager));
        vm.expectRevert(LaunchSettlementVault.InitializationNotAuthorized.selector);
        vault.beforeInitialize(address(strategy), key, uint160(Q96));
    }

    function testTreasuryCannotReleaseBeforeProofAndCanTakePositionAfterSuccess() public {
        _create(false, 0);
        _bid(1 ether);
        vm.prank(treasury);
        vm.expectRevert(LaunchSettlementVault.TreasuryReleaseBlocked.selector);
        vault.releasePosition(treasury);
        _finishAuction();
        factory.finalizeLaunch(launchId);
        vm.prank(stranger);
        vm.expectRevert(LaunchSettlementVault.Unauthorized.selector);
        vault.releaseProceeds(payable(stranger));
        vm.prank(treasury);
        vault.releaseProceeds(payable(treasury));
        assertGt(treasury.balance, 0);
        vm.prank(treasury);
        vault.releasePosition(treasury);
        assertEq(IERC721(address(positionManager)).ownerOf(vault.positionId()), treasury);
        assertTrue(vault.positionReleased());
        vm.prank(treasury);
        vm.expectRevert(LaunchSettlementVault.PositionAlreadyReleased.selector);
        vault.releasePosition(treasury);
        assertEq(uint256(vault.status()), uint256(LaunchSettlementVault.SettlementStatus.Succeeded));
    }

    function testFactoryBindingsMetadataAndNoHiddenCreatorAllocation() public {
        _create(false, 0);
        LaunchRecord memory launch = factory.launchAt(launchId);
        assertEq(launch.id, 1);
        assertEq(launch.creator, creator);
        assertEq(launch.token, address(token));
        assertEq(launch.auction, address(auction));
        assertEq(launch.validationHook, address(capHook));
        assertEq(launch.settlement, address(vault));
        assertEq(launch.treasury, treasury);
        assertEq(launch.claimBlock, END + 2);
        assertEq(token.totalSupply(), 1000 ether);
        assertEq(auction.totalSupply(), 800 ether);
        assertEq(token.balanceOf(creator), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(auction.fundsRecipient(), address(strategy));
        assertEq(auction.tokensRecipient(), address(vault));
        assertEq(address(auction.validationHook()), address(capHook));
        assertEq(token.auction(), address(auction));
        assertEq(factory.getLaunches(1, 50).length, 1);
        assertEq(factory.getLaunches(2, 50).length, 0);
        vm.prank(alice);
        assertEq(factory.createPosition(launchId, 0, 0), address(wrapper));
    }

    function testCloneAndImplementationCannotBeInitializedTwice() public {
        _create(false, 0);
        vm.expectRevert(LaunchSettlementVault.AlreadyInitialized.selector);
        vault.initialize(address(token), treasury, 1, 1, 3000, 60, END + 1);
        vm.expectRevert(LaunchSettlementVault.AlreadyInitialized.selector);
        implementation.initialize(address(token), treasury, 1, 1, 3000, 60, END + 1);
        vm.prank(stranger);
        vm.expectRevert(LaunchSettlementVault.Unauthorized.selector);
        vault.bindAuction(IFinalizedAuction(address(auction)));
        IBidLockFactory boundWrapperFactory = IBidLockFactory(address(factory.wrapperFactory()));
        vm.prank(address(factory));
        vm.expectRevert(LaunchToken.AlreadyBound.selector);
        token.bindAuction(address(auction), boundWrapperFactory);
    }

    function testUntrustedGateAndUnavailableIdentityProviderRejected() public {
        LaunchConfig memory c = _config(false);
        c.phases[0].ensGate = address(fees);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.UnknownENSGate.selector, address(fees)));
        factory.createLaunch(c);
        c.phases[0].ensGate = address(0);
        c.identityEnabled = true;
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.InvalidIdentityConfiguration.selector);
        factory.createLaunch(c);
    }

    function testZeroFeeEconomicsCannotBeChanged() public {
        assertEq(fees.getProtocolFeeAmount(address(0), type(uint256).max), 0);
        vm.expectRevert(ZeroFeeController.FeesAreImmutable.selector);
        fees.setGlobalProtocolFeePips(1);
        vm.expectRevert(ZeroFeeController.FeesAreImmutable.selector);
        fees.setProtocolFeeRecipient(stranger);
    }

    function testBothConstructorsRejectOtherNonzeroFeeControllers() public {
        // Simulate the stock factory reporting a different immutable controller.
        for (uint256 i; i < 2; ++i) {
            address unsupported = i == 0 ? address(implementation) : stranger;
            vm.mockCall(address(ccaFactory), abi.encodeWithSelector(ccaFactory.protocolFeeController.selector),
                abi.encode(unsupported));
            _assertInvalidFeeController("LaunchSettlementVault.sol:LaunchSettlementVault", abi.encode(strategy));
            _assertInvalidFeeController("LaunchpadFactory.sol:LaunchpadFactory",
                abi.encode(strategy, address(0), address(0), implementation));
        }
    }

    function _assertInvalidFeeController(string memory artifact, bytes memory args) internal {
        bytes memory code = abi.encodePacked(vm.getCode(artifact), args);
        address deployed;
        bytes4 reason;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if eq(returndatasize(), 4) {
                returndatacopy(0, 0, 4)
                reason := mload(0)
            }
        }
        assertEq(deployed, address(0));
        assertEq(reason, LaunchpadFactory.InvalidConfiguration.selector);
    }

    function testRejectsTinyLiquidityBudgetsAndAcceptsExactMinimum() public {
        LaunchConfig memory c = _config(false);
        uint128 minimum = 1 << 32;
        c.liquidityAllocationMps = 5_000_000;
        c.requiredCurrencyRaised = 2 * minimum - 1;
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.InvalidConfiguration.selector);
        factory.createLaunch(c);
        c.requiredCurrencyRaised = 2 * minimum;
        c.reserveForLiquidity = minimum - 1;
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.InvalidConfiguration.selector);
        factory.createLaunch(c);
        c.reserveForLiquidity = minimum;
        vm.prank(creator);
        factory.createLaunch(c);
        assertEq(factory.launchCount(), 1);
    }

    function _assertMinimumBudgetsMint(uint256 price, int24 spacing) internal view {
        uint160 sqrtPrice = TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(price, true));
        (Position[] memory positions,) = PositionPlanner.resolve(
            new PositionDefinition[](0), sqrtPrice, spacing,
            CurrencyAmounts(1 << 32, 1 << 32), address(this)
        );
        assertEq(positions.length, 1);
        assertGt(positions[0].liquidity, 0);
        assertGt(positions[0].amount0, 0);
        assertGt(positions[0].amount1, 0);
    }

    function testMinimumBudgetsAtExtremeCcaPricesAndPoolSpacings() public view {
        _assertMinimumBudgetsMint((1 << 32) + 1, 1);
        _assertMinimumBudgetsMint((1 << 32) + 1, 32767);
        _assertMinimumBudgetsMint(type(uint160).max, 1);
        _assertMinimumBudgetsMint(type(uint160).max, 32767);
    }

    function testFuzzMinimumBudgetsMintThroughoutCcaPriceRange(uint160 price, uint16 spacing) public view {
        _assertMinimumBudgetsMint(bound(price, (1 << 32) + 1, type(uint160).max), int24(uint24(bound(spacing, 1, 32767))));
    }

    function testFuzzIssuanceScheduleTotalsExactly(uint32 rawDuration) public {
        uint64 duration = uint64(bound(rawDuration, 1, 10_000_000));
        bytes memory steps = factory.auctionSteps(duration);
        uint256 totalMps;
        uint256 totalBlocks;
        for (uint256 offset; offset < steps.length; offset += 8) {
            (uint24 rate, uint40 blocks_) = steps.get(offset);
            assertGt(rate, 0);
            assertGt(blocks_, 0);
            totalMps += uint256(rate) * blocks_;
            totalBlocks += blocks_;
        }
        assertEq(totalMps, 10_000_000);
        assertEq(totalBlocks, duration);
    }
}
