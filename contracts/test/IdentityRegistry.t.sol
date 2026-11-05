// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {LocalWorldIDFixture} from "./mocks/LocalWorldIDFixture.sol";
import {IdentityENSTestBase} from "./helpers/IdentityENSTestBase.sol";

contract IdentityRegistryTest is IdentityENSTestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant EVE = address(0xE7E);
    uint256 internal constant ROOT = 12345;
    uint256 internal constant HUMAN = 98765;
    LocalWorldIDFixture internal router;
    IdentityRegistry internal registry;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1000);
        router = new LocalWorldIDFixture();
        registry = new IdentityRegistry(address(router), "app_launchpad_test", "join-launchpad", true);
    }

    function testStartsUnverified() public view {
        assertEq(registry.identityOf(ALICE), bytes32(0));
        assertEq(registry.walletCount(registry.identityKey(HUMAN)), 0);
        assertEq(registry.verifiedAt(ALICE), 0);
        assertTrue(registry.localTestOnly());
    }

    function testExternalNullifierMatchesIndependentViemVector() public view {
        assertEq(registry.externalNullifierHash(),
            412293647068464682723101935834659830134178686269693586771061245470604456724);
        assertEq(registry.GROUP_ID(), 1);
    }

    function testSignalEncodingMatchesIndependentUtf8Vector() public {
        // Copy only runtime code to a fixed local test address to make this vector deterministic.
        address fixedAddress = address(0xBEEF);
        vm.etch(fixedAddress, address(registry).code);
        IdentityRegistry fixedRegistry = IdentityRegistry(fixedAddress);
        assertEq(fixedRegistry.expectedSignal(ALICE),
            "hoddr-launchpad-world-v3:31337:0x000000000000000000000000000000000000beef:0x00000000000000000000000000000000000a11ce");
        assertEq(fixedRegistry.expectedSignalHash(ALICE),
            188171323704762000173136932306750075266996340379061111975282825588693208308);
    }

    function testVerifierCallMustSucceedBeforeBinding() public {
        _allow(registry, ALICE, HUMAN, _proof());
        bytes32 identity = _bind(registry, ALICE, HUMAN, _proof());
        assertEq(identity, registry.identityKey(HUMAN));
        assertEq(registry.identityOf(ALICE), identity);
        assertEq(registry.verifiedAt(ALICE), 1000);
        assertEq(registry.walletCount(identity), 1);
        assertEq(registry.walletAt(identity, 0), ALICE);
    }

    function testNoBindingAfterVerifierFailureAndValidRetryWorks() public {
        _allow(registry, ALICE, HUMAN, _proof());
        router.setForceFailure(true);
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        _bind(registry, ALICE, HUMAN, _proof());
        assertEq(registry.identityOf(ALICE), bytes32(0));
        assertEq(registry.walletCount(registry.identityKey(HUMAN)), 0);
        assertEq(registry.verifiedAt(ALICE), 0);
        router.setForceFailure(false);
        _bind(registry, ALICE, HUMAN, _proof());
        assertTrue(registry.identityOf(ALICE) != bytes32(0));
    }

    function testRejectsCopiedProofForAnotherWallet() public {
        _allow(registry, ALICE, HUMAN, _proof());
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        _bind(registry, BOB, HUMAN, _proof());
        assertEq(registry.identityOf(BOB), bytes32(0));
    }

    function testCannotSubmitOnBehalfOfBeneficiary() public {
        _allow(registry, ALICE, HUMAN, _proof());
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.BeneficiaryMustCall.selector, ALICE, EVE));
        vm.prank(EVE);
        registry.verifyAndBind(ALICE, ROOT, HUMAN, _proof());
        assertEq(registry.identityOf(ALICE), bytes32(0));
    }

    function testRejectsZeroBeneficiary() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.BeneficiaryMustCall.selector, address(0), address(this)));
        registry.verifyAndBind(address(0), ROOT, HUMAN, _proof());
    }

    function testReplayOnSameWalletRejected() public {
        _allow(registry, ALICE, HUMAN, _proof());
        _bind(registry, ALICE, HUMAN, _proof());
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletAlreadyBound.selector, ALICE, registry.identityKey(HUMAN)));
        _bind(registry, ALICE, HUMAN, _proof());
        assertEq(registry.walletCount(registry.identityKey(HUMAN)), 1);
    }

    function testAlreadyBoundWalletCannotSwitchHuman() public {
        _allow(registry, ALICE, HUMAN, _proof());
        _bind(registry, ALICE, HUMAN, _proof());
        _allow(registry, ALICE, HUMAN + 1, _proof());
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletAlreadyBound.selector, ALICE, registry.identityKey(HUMAN)));
        _bind(registry, ALICE, HUMAN + 1, _proof());
        assertEq(registry.identityOf(ALICE), registry.identityKey(HUMAN));
        assertEq(registry.walletCount(registry.identityKey(HUMAN + 1)), 0);
    }

    function testSameHumanCanLinkFreshWalletBoundProof() public {
        _allow(registry, ALICE, HUMAN, _proof());
        _bind(registry, ALICE, HUMAN, _proof());
        _allow(registry, BOB, HUMAN, _proof());
        _bind(registry, BOB, HUMAN, _proof());
        bytes32 identity = registry.identityKey(HUMAN);
        assertEq(registry.identityOf(ALICE), identity);
        assertEq(registry.identityOf(BOB), identity);
        assertEq(registry.walletCount(identity), 2);
        assertEq(registry.walletAt(identity, 0), ALICE);
        assertEq(registry.walletAt(identity, 1), BOB);
        address[] memory wallets = registry.walletsOf(identity);
        assertEq(wallets.length, 2);
        assertEq(wallets[0], ALICE);
        assertEq(wallets[1], BOB);
    }

    function testDifferentHumansRemainDifferentIdentities() public {
        _allow(registry, ALICE, HUMAN, _proof());
        _bind(registry, ALICE, HUMAN, _proof());
        _allow(registry, BOB, HUMAN + 1, _proof());
        _bind(registry, BOB, HUMAN + 1, _proof());
        assertTrue(registry.identityOf(ALICE) != registry.identityOf(BOB));
    }

    function testBoundedWalletEnumerationPreventsUnboundedHookWork() public {
        for (uint256 i; i < 32; ++i) {
            address wallet = address(uint160(0x1000 + i));
            _allow(registry, wallet, HUMAN, _proof());
            _bind(registry, wallet, HUMAN, _proof());
        }
        bytes32 identity = registry.identityKey(HUMAN);
        assertEq(registry.walletCount(identity), 32);
        _allow(registry, ALICE, HUMAN, _proof());
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.IdentityWalletLimit.selector, identity));
        _bind(registry, ALICE, HUMAN, _proof());
        assertEq(registry.identityOf(ALICE), bytes32(0));
        assertEq(registry.walletCount(identity), 32);
    }

    function testWrongRootRejectedByVerifier() public {
        _allow(registry, ALICE, HUMAN, _proof());
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        vm.prank(ALICE);
        registry.verifyAndBind(ALICE, ROOT + 1, HUMAN, _proof());
    }

    function testChangedProofWordRejected() public {
        _allow(registry, ALICE, HUMAN, _proof());
        uint256[8] memory changed = _proof();
        changed[3] += 1;
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        _bind(registry, ALICE, HUMAN, changed);
    }

    function testWrongActionExternalNullifierRejected() public {
        IdentityRegistry other = new IdentityRegistry(address(router), "app_launchpad_test", "other-action", true);
        router.allowFixture(ROOT, other.expectedSignalHash(ALICE), HUMAN, registry.externalNullifierHash(), _proof());
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        _bind(other, ALICE, HUMAN, _proof());
        assertEq(other.identityOf(ALICE), bytes32(0));
        assertTrue(other.identityKey(HUMAN) != registry.identityKey(HUMAN));
    }

    function testWrongAppExternalNullifierRejected() public {
        IdentityRegistry other = new IdentityRegistry(address(router), "app_another_app", "join-launchpad", true);
        router.allowFixture(ROOT, other.expectedSignalHash(ALICE), HUMAN, registry.externalNullifierHash(), _proof());
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        _bind(other, ALICE, HUMAN, _proof());
    }

    function testProofForAnotherRegistryCannotBeReplayed() public {
        IdentityRegistry other = new IdentityRegistry(address(router), "app_launchpad_test", "join-launchpad", true);
        _allow(registry, ALICE, HUMAN, _proof());
        vm.expectRevert(LocalWorldIDFixture.InvalidFixture.selector);
        _bind(other, ALICE, HUMAN, _proof());
        assertTrue(other.expectedSignalHash(ALICE) != registry.expectedSignalHash(ALICE));
    }

    function testDeploymentChainChangeRejected() public {
        _allow(registry, ALICE, HUMAN, _proof());
        vm.chainId(1337);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WrongChain.selector, uint256(31337), uint256(1337)));
        _bind(registry, ALICE, HUMAN, _proof());
    }

    function testRejectsNullifierOutsideField() public {
        vm.expectRevert(IdentityRegistry.InvalidNullifier.selector);
        _bind(registry, ALICE, 0, _proof());
        uint256 field = registry.SNARK_SCALAR_FIELD();
        vm.expectRevert(IdentityRegistry.InvalidNullifier.selector);
        _bind(registry, ALICE, field, _proof());
    }

    function testRejectsRootOutsideField() public {
        vm.expectRevert(IdentityRegistry.InvalidRoot.selector);
        vm.prank(ALICE);
        registry.verifyAndBind(ALICE, 0, HUMAN, _proof());
        uint256 field = registry.SNARK_SCALAR_FIELD();
        vm.expectRevert(IdentityRegistry.InvalidRoot.selector);
        vm.prank(ALICE);
        registry.verifyAndBind(ALICE, field, HUMAN, _proof());
    }

    function testLocalModeCannotDeployOnSepolia() public {
        vm.chainId(11155111);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnsupportedChain.selector, uint256(11155111)));
        new IdentityRegistry(address(router), "app_launchpad_test", "join-launchpad", true);
    }

    function testRealModeRejectsNoncanonicalRouter() public {
        vm.chainId(11155111);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnexpectedRouter.selector, address(router)));
        new IdentityRegistry(address(router), "app_launchpad_test", "join-launchpad", false);
    }

    function testRealModePinsCanonicalSepoliaRouter() public {
        address canonical = registry.SEPOLIA_WORLD_ID_ROUTER();
        // Constructor policy unit test only: no claim that this etched fixture is a real Router.
        vm.etch(canonical, address(router).code);
        vm.chainId(11155111);
        IdentityRegistry realMode = new IdentityRegistry(canonical, "app_launchpad_test", "join-launchpad", false);
        assertFalse(realMode.localTestOnly());
        assertEq(address(realMode.worldIdRouter()), canonical);
        assertEq(realMode.deploymentChainId(), 11155111);
    }

    function testRealModeRejectsUnreviewedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnsupportedChain.selector, uint256(1)));
        new IdentityRegistry(address(router), "app_launchpad_test", "join-launchpad", false);
    }

    function testLocalModeMustBeExplicitOnLocalChain() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnsupportedChain.selector, uint256(31337)));
        new IdentityRegistry(address(router), "app_launchpad_test", "join-launchpad", false);
    }

    function testInvalidConfigurationRejected() public {
        vm.expectRevert(IdentityRegistry.InvalidConfiguration.selector);
        new IdentityRegistry(address(0x123456), "app_launchpad_test", "join-launchpad", true);
        vm.expectRevert(IdentityRegistry.InvalidConfiguration.selector);
        new IdentityRegistry(address(router), "not_an_app", "join-launchpad", true);
        vm.expectRevert(IdentityRegistry.InvalidConfiguration.selector);
        new IdentityRegistry(address(router), "app_launchpad_test", "", true);
    }

    function testFuzzWalletCannotChangeIdentity(uint256 first, uint256 second) public {
        uint256 field = registry.SNARK_SCALAR_FIELD();
        first = 1 + first % (field - 1);
        second = 1 + second % (field - 1);
        _allow(registry, ALICE, first, _proof());
        _bind(registry, ALICE, first, _proof());
        _allow(registry, ALICE, second, _proof());
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletAlreadyBound.selector, ALICE, registry.identityKey(first)));
        _bind(registry, ALICE, second, _proof());
        assertEq(registry.identityOf(ALICE), registry.identityKey(first));
        assertEq(registry.walletCount(registry.identityKey(first)), 1);
    }

    function _allow(IdentityRegistry target, address wallet, uint256 nullifier, uint256[8] memory proof) internal {
        router.allowFixture(ROOT, target.expectedSignalHash(wallet), nullifier, target.externalNullifierHash(), proof);
    }

    function _bind(IdentityRegistry target, address wallet, uint256 nullifier, uint256[8] memory proof)
        internal returns (bytes32)
    {
        vm.prank(wallet);
        return target.verifyAndBind(wallet, ROOT, nullifier, proof);
    }

    function _proof() internal pure returns (uint256[8] memory) {
        return [uint256(11), 22, 33, 44, 55, 66, 77, 88];
    }
}
