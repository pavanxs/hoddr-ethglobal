// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PhaseCapHook} from "../src/PhaseCapHook.sol";
import {PhaseConfig, LockOption, AllowancePreview} from "../src/LaunchpadTypes.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IBidLockFactory, BidLockMetadata} from "../src/interfaces/IBidLockFactory.sol";
import {IENSDomainGate} from "../src/interfaces/IENSDomainGate.sol";

contract CapIdentityFixture is IIdentityRegistry {
    mapping(address => bytes32) public identityOf;
    mapping(bytes32 => address[]) private _wallets;
    uint256 public forcedCount;

    function bind(address account, bytes32 id) external {
        require(id != bytes32(0) && identityOf[account] == bytes32(0) && _wallets[id].length < 32, "binding");
        identityOf[account] = id;
        _wallets[id].push(account);
    }
    function walletCount(bytes32 id) external view returns (uint256) {
        return forcedCount == 0 ? _wallets[id].length : forcedCount;
    }
    function walletAt(bytes32 id, uint256 index) external view returns (address) { return _wallets[id][index]; }
    function setForcedCount(uint256 count) external { forcedCount = count; }
}

contract CapWrapperFixture is IBidLockFactory {
    mapping(address => BidLockMetadata) private _metadata;
    mapping(address => mapping(address => address)) public wrapperFor;

    function register(address wrapper, address beneficiary, address auction, address hook, uint8 lockOption) external {
        wrapperFor[auction][beneficiary] = wrapper;
        _metadata[wrapper] = BidLockMetadata(beneficiary, auction, hook, lockOption);
    }
    function wrapperInfo(address wrapper) external view returns (BidLockMetadata memory) { return _metadata[wrapper]; }
}

contract CapAuctionFixture {
    address public validationHook;
    address public currency;
    uint64 public startBlock;
    uint64 public endBlock;

    constructor(address hook, uint64 start, uint64 end) {
        validationHook = hook;
        startBlock = start;
        endBlock = end;
    }
    function submit(address owner, address sender, uint128 amount, bytes calldata evidence) external {
        PhaseCapHook(validationHook).validate(1 << 96, amount, owner, sender, evidence);
    }
}

contract CapENSFixture is IENSDomainGate {
    address public owner;
    bytes32 public evidenceHash;
    bool public broken;

    function configure(address account, bytes calldata evidence) external {
        owner = account;
        evidenceHash = keccak256(evidence);
    }
    function setBroken(bool value) external { broken = value; }
    function isEligible(address account, bytes calldata evidence) external view returns (bool) {
        require(!broken, "offline gate");
        return account == owner && keccak256(evidence) == evidenceHash;
    }
}

contract PhaseCapHookTest is Test {
    PhaseCapHook hook;
    CapIdentityFixture identity;
    CapWrapperFixture wrappers;
    CapAuctionFixture auction;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address aliceWrapper = address(0xAA01);
    address bobWrapper = address(0xBB01);
    bytes32 constant PERSON = keccak256("one verified person");

    function setUp() public {
        identity = new CapIdentityFixture();
        wrappers = new CapWrapperFixture();
        _deploy(false, address(0), false);
        vm.roll(100);
    }

    function _phases(bool verifiedOnly, address gate, bool singleBlock) internal pure returns (PhaseConfig[] memory p) {
        p = new PhaseConfig[](singleBlock ? 1 : 2);
        p[0] = PhaseConfig(100, singleBlock ? 101 : 110, 1 ether, 2 ether, 3 ether, 6 ether, 0.1 ether, verifiedOnly, gate);
        if (!singleBlock) p[1] = PhaseConfig(110, 120, 2 ether, 3 ether, 5 ether, 8 ether, 0.1 ether, false, address(0));
    }

    function _options() internal pure returns (LockOption[] memory options) {
        options = new LockOption[](3);
        options[0] = LockOption(0, 10_000);
        options[1] = LockOption(30 days, 15_000);
        options[2] = LockOption(90 days, 20_000);
    }

    function _deploy(bool verifiedOnly, address gate, bool singleBlock) internal {
        hook = new PhaseCapHook(address(this), address(wrappers), identity, _phases(verifiedOnly, gate, singleBlock), _options());
        auction = new CapAuctionFixture(address(hook), 100, singleBlock ? 101 : 120);
        hook.bindAuction(address(auction));
        _wrapper(alice, aliceWrapper, 0);
        _wrapper(bob, bobWrapper, 0);
    }

    function _wrapper(address account, address wrapper, uint8 option) internal {
        wrappers.register(wrapper, account, address(auction), address(hook), option);
    }
    function _bid(address wrapper, uint128 amount) internal { auction.submit(wrapper, wrapper, amount, ""); }

    function testRampBoundariesAndPhaseReset() public {
        assertEq(hook.preview(alice, 0).cap, 1 ether);
        vm.roll(104);
        assertEq(hook.preview(alice, 0).cap, 1 ether + uint256(1 ether) * 4 / 9);
        vm.roll(109);
        _bid(aliceWrapper, 1 ether);
        assertEq(hook.preview(alice, 0).cap, 2 ether);
        vm.roll(110);
        AllowancePreview memory p = hook.preview(alice, 0);
        assertEq(p.phaseIndex, 1);
        assertEq(p.cap, 2 ether);
        assertEq(p.committed, 0);
        assertEq(hook.accountCommitted(alice, 0), 1 ether);
        vm.roll(119);
        assertEq(hook.preview(alice, 0).cap, 3 ether);
        vm.roll(120);
        assertFalse(hook.preview(alice, 0).active);
        vm.expectRevert(PhaseCapHook.InactivePhase.selector);
        _bid(aliceWrapper, 0.1 ether);
    }

    function testBeforeStartInactiveAndSingleBlockUsesEndCap() public {
        vm.roll(99);
        assertFalse(hook.preview(alice, 0).active);
        vm.expectRevert(PhaseCapHook.InactivePhase.selector);
        _bid(aliceWrapper, 0.1 ether);
        _deploy(false, address(0), true);
        vm.roll(100);
        assertEq(hook.preview(alice, 0).cap, 2 ether);
        assertTrue(hook.preview(alice, 0).active);
        vm.roll(101);
        assertFalse(hook.preview(alice, 0).active);
    }

    function testVerifiedWalletsShareOneBudget() public {
        identity.bind(alice, PERSON);
        identity.bind(bob, PERSON);
        _bid(aliceWrapper, 2 ether);
        _bid(bobWrapper, 1 ether);
        AllowancePreview memory p = hook.preview(bob, 0);
        assertEq(p.accountCommitted, 1 ether);
        assertEq(p.committed, 3 ether);
        assertEq(p.remaining, 0);
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.CapExceeded.selector, 3 ether, 3 ether, 0.1 ether));
        _bid(aliceWrapper, 0.1 ether);
    }

    function testEnrollmentDoesNotResetAccountBudget() public {
        _bid(aliceWrapper, 0.9 ether);
        identity.bind(alice, PERSON);
        AllowancePreview memory p = hook.preview(alice, 0);
        assertTrue(p.verified);
        assertEq(p.committed, 0.9 ether);
        assertEq(p.remaining, 2.1 ether);
        _bid(aliceWrapper, 2.1 ether);
        assertEq(hook.accountCommitted(alice, 0), 3 ether);
    }

    function testLinkAfterUnverifiedSpendsIncludesBothHistories() public {
        _bid(aliceWrapper, 0.8 ether);
        _bid(bobWrapper, 0.9 ether);
        identity.bind(alice, PERSON);
        identity.bind(bob, PERSON);
        AllowancePreview memory p = hook.preview(alice, 0);
        assertEq(p.committed, 1.7 ether);
        assertEq(p.remaining, 1.3 ether);
        _bid(bobWrapper, 1.3 ether);
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.CapExceeded.selector, 3 ether, 3 ether, 0.1 ether));
        _bid(aliceWrapper, 0.1 ether);
    }

    function testLinkShorterUsedWalletReducesFutureCapWithoutErasingHistory() public {
        _wrapper(alice, aliceWrapper, 2);
        identity.bind(alice, PERSON);
        _bid(aliceWrapper, 4 ether);
        _bid(bobWrapper, 0.5 ether);
        identity.bind(bob, PERSON);
        AllowancePreview memory p = hook.preview(alice, 2);
        assertEq(p.effectiveLockOptionIndex, 0);
        assertEq(p.effectiveMultiplierBps, 10_000);
        assertEq(p.cap, 3 ether);
        assertEq(p.committed, 4.5 ether);
        assertEq(p.remaining, 0);
        assertEq(hook.accountCommitted(alice, 0), 4 ether);
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.CapExceeded.selector, 3 ether, 4.5 ether, 0.1 ether));
        _bid(aliceWrapper, 0.1 ether);
    }

    function testNewShorterCandidateCannotSpendUnderOldLargerBonus() public {
        identity.bind(alice, PERSON);
        identity.bind(bob, PERSON);
        _wrapper(alice, aliceWrapper, 2);
        _bid(aliceWrapper, 4 ether);
        assertEq(hook.preview(alice, 2).cap, 6 ether);
        assertEq(hook.preview(bob, 0).cap, 3 ether);
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.CapExceeded.selector, 3 ether, 4 ether, 0.1 ether));
        _bid(bobWrapper, 0.1 ether);
        assertFalse(hook.hasCommitment(bob));
        assertEq(hook.preview(alice, 2).cap, 6 ether);
    }

    function testLowestCommitmentPersistsAcrossPhases() public {
        identity.bind(alice, PERSON);
        identity.bind(bob, PERSON);
        _wrapper(bob, bobWrapper, 2);
        _bid(aliceWrapper, 0.1 ether);
        vm.roll(110);
        AllowancePreview memory p = hook.preview(bob, 2);
        assertEq(p.committed, 0);
        assertEq(p.effectiveLockOptionIndex, 0);
        assertEq(p.cap, 5 ether);
        _bid(bobWrapper, 5 ether);
    }

    function testExistingWrapperOverridesMisleadingPreviewOption() public {
        AllowancePreview memory p = hook.preview(alice, 2);
        assertEq(p.wrapper, aliceWrapper);
        assertEq(p.effectiveLockOptionIndex, 0);
        assertEq(p.cap, 1 ether);
    }

    function testDifferentUnverifiedAccountsAreExplicitlySeparate() public {
        _bid(aliceWrapper, 1 ether);
        _bid(bobWrapper, 1 ether);
        assertFalse(hook.preview(alice, 0).verified);
        assertEq(hook.preview(alice, 0).committed, 1 ether);
        assertEq(hook.preview(bob, 0).committed, 1 ether);
    }

    function testMinimumBidAndExactCap() public {
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.BidBelowMinimum.selector, 0.1 ether, 0.1 ether - 1));
        _bid(aliceWrapper, 0.1 ether - 1);
        _bid(aliceWrapper, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.CapExceeded.selector, 1 ether, 1 ether, 0.1 ether));
        _bid(aliceWrapper, 0.1 ether);
    }

    function testVerifiedOnlyRequiresBoundIdentity() public {
        _deploy(true, address(0), false);
        assertFalse(hook.preview(alice, 0).identityAllowed);
        vm.expectRevert(PhaseCapHook.HumanVerificationRequired.selector);
        _bid(aliceWrapper, 0.1 ether);
        identity.bind(alice, PERSON);
        _bid(aliceWrapper, 0.1 ether);
        assertTrue(hook.preview(alice, 0).identityAllowed);
    }

    function testENSGateIsCheckedForAuthenticatedBeneficiary() public {
        CapENSFixture gate = new CapENSFixture();
        bytes memory evidence = abi.encode("active descendant");
        gate.configure(alice, evidence);
        _deploy(false, address(gate), false);
        (AllowancePreview memory p, bool ensEligible, bool eligible) = hook.previewWithEvidence(alice, 0, evidence);
        assertTrue(p.ensRequired);
        assertTrue(ensEligible);
        assertTrue(eligible);
        auction.submit(aliceWrapper, aliceWrapper, 0.1 ether, evidence);
        vm.expectRevert(PhaseCapHook.ENSNameRequired.selector);
        auction.submit(bobWrapper, bobWrapper, 0.1 ether, evidence);
        vm.expectRevert(PhaseCapHook.ENSNameRequired.selector);
        auction.submit(aliceWrapper, aliceWrapper, 0.1 ether, "wrong");
        gate.setBroken(true);
        (, ensEligible, eligible) = hook.previewWithEvidence(alice, 0, evidence);
        assertFalse(ensEligible);
        assertFalse(eligible);
    }

    function testRejectsCallerOwnerSenderAndBeneficiaryInjection() public {
        vm.expectRevert(PhaseCapHook.Unauthorized.selector);
        hook.validate(1, 0.1 ether, aliceWrapper, aliceWrapper, "");
        vm.expectRevert(PhaseCapHook.InvalidWrapper.selector);
        auction.submit(aliceWrapper, bobWrapper, 0.1 ether, "");
        vm.expectRevert(PhaseCapHook.InvalidWrapper.selector);
        auction.submit(address(0xBAD), address(0xBAD), 0.1 ether, "");
        wrappers.register(aliceWrapper, alice, address(0xBAD), address(hook), 0);
        vm.expectRevert(PhaseCapHook.InvalidWrapper.selector);
        _bid(aliceWrapper, 0.1 ether);
    }

    function testCannotSwapWrapperAfterCommitmentToIncreaseBonus() public {
        _bid(aliceWrapper, 0.5 ether);
        // Production factory cannot do this; the hook also detects inconsistent metadata.
        _wrapper(alice, aliceWrapper, 2);
        vm.expectRevert(PhaseCapHook.LockOptionMismatch.selector);
        _bid(aliceWrapper, 0.1 ether);
    }

    function testOldNonCanonicalWrapperCannotReuseBeneficiary() public {
        _wrapper(alice, address(0xAA02), 0);
        vm.expectRevert(PhaseCapHook.InvalidWrapper.selector);
        _bid(aliceWrapper, 0.1 ether);
    }

    function testOnlyFactoryBindsAuctionOnce() public {
        vm.prank(alice);
        vm.expectRevert(PhaseCapHook.Unauthorized.selector);
        hook.bindAuction(address(auction));
        vm.expectRevert(PhaseCapHook.AuctionAlreadyBound.selector);
        hook.bindAuction(address(auction));
    }

    function testEvidenceIsBounded() public {
        vm.expectRevert(PhaseCapHook.EvidenceTooLarge.selector);
        auction.submit(aliceWrapper, aliceWrapper, 0.1 ether, new bytes(4097));
    }

    function testAtMost32LinkedWalletsAndBoundedPreviewCost() public {
        for (uint256 i; i < 32; ++i) {
            address account = address(uint160(1000 + i));
            address wrapper = address(uint160(2000 + i));
            _wrapper(account, wrapper, 2);
            _bid(wrapper, 0.1 ether);
            identity.bind(account, PERSON);
        }
        uint256 beforeGas = gasleft();
        AllowancePreview memory p = hook.preview(address(1000), 2);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("32-wallet preview gas (fixture)", used);
        assertLt(used, 2_000_000);
        assertEq(p.committed, 3.2 ether);
        assertEq(p.cap, 6 ether);
        identity.setForcedCount(33);
        vm.expectRevert(PhaseCapHook.InvalidIdentityRegistry.selector);
        hook.preview(address(1000), 2);
    }

    function testFuzzRampNeverDecreases(uint8 first, uint8 second) public {
        uint256 a = bound(first, 100, 109);
        uint256 b = bound(second, a, 109);
        vm.roll(a);
        uint256 capA = hook.preview(alice, 0).cap;
        vm.roll(b);
        uint256 capB = hook.preview(alice, 0).cap;
        assertLe(capA, capB);
        assertGe(capA, 1 ether);
        assertLe(capB, 2 ether);
    }

    function testFuzzTwoWalletSplitsCannotExceedPersonCap(uint128 firstAmount) public {
        identity.bind(alice, PERSON);
        identity.bind(bob, PERSON);
        uint128 amount = uint128(bound(firstAmount, 0.1 ether, 2.9 ether));
        _bid(aliceWrapper, amount);
        _bid(bobWrapper, uint128(3 ether - amount));
        assertEq(hook.preview(alice, 0).remaining, 0);
        vm.expectRevert(abi.encodeWithSelector(PhaseCapHook.CapExceeded.selector, 3 ether, 3 ether, 0.1 ether));
        _bid(bobWrapper, 0.1 ether);
    }
}
