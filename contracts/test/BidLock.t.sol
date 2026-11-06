// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {BidLock} from "../src/BidLock.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockOption} from "../src/LaunchpadTypes.sol";
import {IBidLockFactory, BidLockMetadata} from "../src/interfaces/IBidLockFactory.sol";
import {IPurchasedTokenReceiver} from "../src/interfaces/IPurchasedTokenReceiver.sol";
import {IdentityENSTestBase} from "./helpers/IdentityENSTestBase.sol";

interface VmBidLockFunds { function deal(address account, uint256 balance) external; }

abstract contract LocalLockFixture {
    address internal immutable fixtureOwner = msg.sender;
    constructor() { require(block.chainid == 31337 || block.chainid == 1337, "local fixture only"); }
    modifier fixtureOwnerOnly() { require(msg.sender == fixtureOwner, "fixture owner only"); _; }
}

/// @dev LOCAL UNIT TEST ONLY. Models payout/refund ownership, not CCA pricing or settlement math.
contract LocalLockAuctionFixture is LocalLockFixture {
    struct Bid { address owner; uint128 amount; uint256 payout; uint256 refund; bool claimed; bool exited; }
    address public immutable token;
    address public immutable currency;
    mapping(uint256 id => Bid bid) private _bids;
    uint256 public nextId = 1;
    uint256 public lastMaxPrice;
    uint256 public lastPreviousTick;
    uint128 public lastAmount;
    address public lastOwner;
    address public lastCaller;
    bytes32 public lastEvidenceHash;
    uint64 public lastCheckpoint;
    uint64 public lastOutbidBlock;

    error UnknownFixtureBid();
    error AlreadyClaimed();
    error WrongFixtureOwner();

    constructor(address token_, address currency_) { token = token_; currency = currency_; }
    receive() external payable {}

    function submitBid(uint256 price, uint128 amount, address owner, uint256 previousTick, bytes calldata evidence)
        external payable returns (uint256 id)
    {
        require(msg.sender == owner && msg.value == amount && amount != 0, "wrapper-owned bid only");
        id = nextId++;
        _bids[id] = Bid(owner, amount, 0, 0, false, false);
        lastMaxPrice = price; lastAmount = amount; lastOwner = owner; lastCaller = msg.sender;
        lastPreviousTick = previousTick; lastEvidenceHash = keccak256(evidence);
    }

    function setOutcome(uint256 id, uint256 payout, uint256 refund) external fixtureOwnerOnly {
        if (_bids[id].owner == address(0)) revert UnknownFixtureBid();
        require(refund <= _bids[id].amount, "refund exceeds deposited budget");
        _bids[id].payout = payout; _bids[id].refund = refund;
    }

    function claimTokens(uint256 id) public {
        Bid storage bid = _bids[id];
        if (bid.owner == address(0)) revert UnknownFixtureBid();
        if (bid.claimed) revert AlreadyClaimed();
        bid.claimed = true;
        require(IERC20(token).transfer(bid.owner, bid.payout), "token transfer failed");
    }

    function claimTokensBatch(address owner, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            if (_bids[ids[i]].owner != owner) revert WrongFixtureOwner();
            claimTokens(ids[i]);
        }
    }

    function exitBid(uint256 id) public {
        Bid storage bid = _bids[id];
        if (bid.owner == address(0)) revert UnknownFixtureBid();
        require(!bid.exited, "already exited");
        bid.exited = true;
        (bool ok,) = payable(bid.owner).call{value: bid.refund}("");
        require(ok, "refund failed");
    }

    function exitPartiallyFilledBid(uint256 id, uint64 checkpoint, uint64 outbidBlock) external {
        lastCheckpoint = checkpoint; lastOutbidBlock = outbidBlock; exitBid(id);
    }

    function pay(address recipient, uint256 amount) external fixtureOwnerOnly {
        require(IERC20(token).transfer(recipient, amount), "token transfer failed");
    }

    function isClaimed(uint256 id) external view returns (bool) { return _bids[id].claimed; }
}

/// @dev LOCAL UNIT TEST metadata stub. Production uses the immutable BidLockFactory path.
contract LocalLockMetadataFixture is LocalLockFixture, IBidLockFactory {
    mapping(address wrapper => BidLockMetadata meta) private _metadata;
    mapping(address auction => mapping(address beneficiary => address wrapper)) public override wrapperFor;

    function register(address wrapper, BidLockMetadata calldata meta) external fixtureOwnerOnly {
        _metadata[wrapper] = meta;
        wrapperFor[meta.auction][meta.beneficiary] = wrapper;
    }

    function wrapperInfo(address wrapper) external view override returns (BidLockMetadata memory) {
        return _metadata[wrapper];
    }
}

contract LocalRejectPurchasedFixture is LocalLockFixture, IPurchasedTokenReceiver {
    error CallbackRefused();
    function onPurchasedTokensReceived(uint256) external pure { revert CallbackRefused(); }
}

contract LocalRejectNativeFixture is LocalLockFixture {
    receive() external payable { revert("no native transfer"); }
}

contract LocalReentrantBeneficiaryFixture is LocalLockFixture {
    BidLock public lock;
    bool public nestedSucceeded;
    bytes4 public nestedError;
    uint256 public received;
    function configure(BidLock value) external fixtureOwnerOnly { lock = value; }
    function withdraw() external fixtureOwnerOnly { lock.withdrawRefunds(payable(address(this))); }
    receive() external payable {
        received += msg.value;
        (bool ok, bytes memory result) = address(lock).call(abi.encodeCall(BidLock.withdrawRefunds, (payable(address(this)))));
        nestedSucceeded = ok;
        if (result.length >= 4) nestedError = bytes4(result);
    }
}

contract BidLockTest is IdentityENSTestBase {
    VmBidLockFunds internal constant vmFunds = VmBidLockFunds(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant EVE = address(0xE7E);
    uint128 internal constant BUDGET = 1 ether;
    uint64 internal constant DURATION = 1000;
    LaunchToken internal token;
    LocalLockAuctionFixture internal auction;
    LocalLockMetadataFixture internal metadata;
    BidLock internal lock;

    receive() external payable {}

    function setUp() public {
        vm.chainId(31337); vm.warp(1000);
        vmFunds.deal(address(this), 100 ether); vmFunds.deal(ALICE, 100 ether); vmFunds.deal(EVE, 100 ether);
        token = new LaunchToken("Community", "COM", 1_000_000, address(this));
        auction = new LocalLockAuctionFixture(address(token), address(0));
        metadata = new LocalLockMetadataFixture();
        token.bindAuction(address(auction), metadata);
        lock = _newLock(ALICE, DURATION, 0);
        token.transfer(address(auction), 100_000);
    }

    function testBidIsAuthenticatedAndWrapperOwnsAuctionPosition() public {
        bytes memory evidence = abi.encode("exact-ens-evidence");
        vm.prank(ALICE);
        uint256 id = lock.bid{value: BUDGET}(2 << 96, BUDGET, 1 << 96, evidence);
        assertEq(auction.lastOwner(), address(lock));
        assertEq(auction.lastCaller(), address(lock));
        assertEq(auction.lastAmount(), BUDGET);
        assertEq(auction.lastMaxPrice(), 2 << 96);
        assertEq(auction.lastPreviousTick(), 1 << 96);
        assertEq(auction.lastEvidenceHash(), keccak256(evidence));
        assertTrue(lock.ownsBid(id)); assertEq(lock.bidCount(), 1); assertEq(lock.bidIdAt(0), id);
    }

    function testBeneficiaryCannotBeSpoofedForBid() public {
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(EVE);
        lock.bid{value: BUDGET}(2 << 96, BUDGET, 0, "");
        assertEq(lock.bidCount(), 0);
    }

    function testBidRequiresExactPositiveBudget() public {
        vm.expectRevert(BidLock.InvalidAmount.selector); vm.prank(ALICE);
        lock.bid(2 << 96, 0, 0, "");
        vm.expectRevert(BidLock.InvalidAmount.selector); vm.prank(ALICE);
        lock.bid{value: BUDGET - 1}(2 << 96, BUDGET, 0, "");
    }

    function testPositiveAuthenticatedPayoutStartsClock() public {
        uint256 id = _bidWithOutcome(lock, 100, 0);
        vm.prank(EVE); lock.claimBid(id);
        assertEq(token.balanceOf(address(lock)), 100);
        assertEq(lock.firstClaimTime(), 1000); assertEq(lock.unlockAt(), 2000);
        assertEq(lock.purchasedReceived(), 100); assertEq(lock.purchasedOutstanding(), 100);
        assertFalse(lock.canWithdrawPurchased());
    }

    function testPermissionlessDirectAuctionClaimStartsSameClock() public {
        uint256 id = _bidWithOutcome(lock, 100, 0);
        vm.prank(EVE); auction.claimTokens(id);
        assertTrue(auction.isClaimed(id));
        assertEq(lock.firstClaimTime(), 1000); assertEq(lock.unlockAt(), 2000);
        assertEq(lock.purchasedReceived(), 100);
    }

    function testDonationsCannotStartOrAgeClock() public {
        token.transfer(address(lock), 40);
        vm.warp(5000);
        token.approve(EVE, 10); vm.prank(EVE); token.transferFrom(address(this), address(lock), 10);
        assertEq(lock.firstClaimTime(), 0); assertEq(lock.unlockAt(), 0); assertEq(lock.purchasedReceived(), 0);
        uint256 id = _bidWithOutcome(lock, 100, 0);
        auction.claimTokens(id);
        assertEq(lock.firstClaimTime(), 5000); assertEq(lock.unlockAt(), 6000);
        assertEq(token.balanceOf(address(lock)), 150); assertEq(lock.purchasedReceived(), 100);
    }

    function testZeroPayoutDoesNotActivateClock() public {
        uint256 zeroId = _bidWithOutcome(lock, 0, 0);
        auction.claimTokens(zeroId);
        assertEq(lock.firstClaimTime(), 0); assertEq(lock.purchasedReceived(), 0);
        vm.warp(1500);
        uint256 positiveId = _bidWithOutcome(lock, 100, 0);
        auction.claimTokens(positiveId);
        assertEq(lock.firstClaimTime(), 1500); assertEq(lock.unlockAt(), 2500);
    }

    function testLaterPayoutPreservesFirstUnlock() public {
        auction.claimTokens(_bidWithOutcome(lock, 100, 0));
        vm.warp(1500);
        auction.claimTokens(_bidWithOutcome(lock, 50, 0));
        assertEq(lock.firstClaimTime(), 1000); assertEq(lock.unlockAt(), 2000);
        assertEq(lock.purchasedReceived(), 150);
        vm.warp(2000); vm.prank(ALICE); lock.withdrawTokens(ALICE);
        vm.warp(2500); auction.claimTokens(_bidWithOutcome(lock, 25, 0));
        assertEq(lock.firstClaimTime(), 1000); assertEq(lock.unlockAt(), 2000);
        assertEq(lock.purchasedOutstanding(), 25);
        vm.prank(ALICE); assertEq(lock.withdrawTokens(ALICE), 25);
        assertEq(token.balanceOf(ALICE), 175);
    }

    function testMinimumDateAndDurationBothApply() public {
        BidLock dated = _newLock(ALICE, DURATION, 5000);
        auction.claimTokens(_bidWithOutcome(dated, 100, 0));
        assertEq(dated.unlockAt(), 5000);
        BidLock pastDate = _newLock(ALICE, DURATION, 500);
        auction.claimTokens(_bidWithOutcome(pastDate, 100, 0));
        assertEq(pastDate.unlockAt(), 2000);
    }

    function testNoLockOptionStillRequiresActualPurchasedTokens() public {
        BidLock immediate = _newLock(ALICE, 0, 0);
        assertFalse(immediate.canWithdrawPurchased());
        auction.claimTokens(_bidWithOutcome(immediate, 100, 0));
        assertTrue(immediate.canWithdrawPurchased());
        assertEq(immediate.unlockAt(), 1000);
    }

    function testPurchasedWithdrawalBlockedUntilExactUnlock() public {
        auction.claimTokens(_bidWithOutcome(lock, 100, 0));
        vm.warp(1999);
        vm.expectRevert(abi.encodeWithSelector(BidLock.TokensStillLocked.selector, uint256(2000)));
        vm.prank(ALICE); lock.withdrawTokens(ALICE);
        vm.warp(2000); vm.prank(ALICE); assertEq(lock.withdrawTokens(BOB), 100);
        assertEq(token.balanceOf(BOB), 100); assertEq(lock.purchasedReleased(), 100);
        assertFalse(lock.canWithdrawPurchased());
        vm.expectRevert(BidLock.NoPurchasedTokens.selector); vm.prank(ALICE); lock.withdrawTokens(ALICE);
    }

    function testDonatedTokensRecoverableWithoutReleasingPurchasedBalance() public {
        auction.claimTokens(_bidWithOutcome(lock, 100, 0));
        token.transfer(address(lock), 30);
        vm.prank(ALICE); assertEq(lock.withdrawDonatedTokens(BOB), 30);
        assertEq(token.balanceOf(BOB), 30); assertEq(token.balanceOf(address(lock)), 100);
        assertEq(lock.purchasedOutstanding(), 100); assertEq(lock.purchasedReleased(), 0);
        assertFalse(lock.canWithdrawPurchased());
        vm.expectRevert(BidLock.NothingToWithdraw.selector); vm.prank(ALICE); lock.withdrawDonatedTokens(BOB);
    }

    function testOnlyDonationsDoNotPretendToBePurchasedTokens() public {
        token.transfer(address(lock), 30);
        vm.expectRevert(BidLock.NoPurchasedTokens.selector); vm.prank(ALICE); lock.withdrawTokens(ALICE);
        vm.prank(ALICE); assertEq(lock.withdrawDonatedTokens(ALICE), 30);
        assertEq(lock.firstClaimTime(), 0);
    }

    function testUnlockedWithdrawalIncludesDonationsButPurchasedAccountingStaysExact() public {
        auction.claimTokens(_bidWithOutcome(lock, 100, 0));
        token.transfer(address(lock), 30);
        vm.warp(2000); vm.prank(ALICE); assertEq(lock.withdrawTokens(ALICE), 130);
        assertEq(lock.purchasedReleased(), 100); assertEq(lock.purchasedOutstanding(), 0);
        assertEq(token.balanceOf(ALICE), 130);
    }

    function testRefundsRemainAvailableDuringLockWithoutAnyProof() public {
        uint256 id = _bidWithOutcome(lock, 100, BUDGET / 2);
        auction.claimTokens(id); vm.prank(EVE); lock.exitBid(id);
        assertEq(lock.availableRefund(), BUDGET / 2);
        uint256 beforeBalance = BOB.balance;
        vm.prank(ALICE); assertEq(lock.withdrawRefunds(payable(BOB)), BUDGET / 2);
        assertEq(BOB.balance - beforeBalance, BUDGET / 2);
        assertEq(lock.availableRefund(), 0); assertEq(lock.purchasedOutstanding(), 100);
        assertFalse(lock.canWithdrawPurchased());
    }

    function testUnsuccessfulSaleRefundDoesNotStartTokenClock() public {
        uint256 id = _bidWithOutcome(lock, 0, BUDGET);
        vm.prank(EVE); lock.exitBid(id);
        vm.prank(ALICE); assertEq(lock.withdrawRefunds(payable(ALICE)), BUDGET);
        assertEq(lock.firstClaimTime(), 0); assertEq(lock.purchasedReceived(), 0);
    }

    function testPartialExitForwardsHintsAndRefundsToWrapper() public {
        uint256 id = _bidWithOutcome(lock, 100, BUDGET / 4);
        vm.prank(EVE); lock.exitPartiallyFilledBid(id, 50, 60);
        assertEq(auction.lastCheckpoint(), 50); assertEq(auction.lastOutbidBlock(), 60);
        assertEq(address(lock).balance, BUDGET / 4);
    }

    function testUnauthorizedBeneficiaryOperationsRejected() public {
        uint256 id = _bidWithOutcome(lock, 100, BUDGET / 4);
        auction.claimTokens(id); lock.exitBid(id); token.transfer(address(lock), 20); vm.warp(2000);
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(EVE); lock.withdrawTokens(EVE);
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(EVE); lock.withdrawDonatedTokens(EVE);
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(EVE); lock.withdrawRefunds(payable(EVE));
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(EVE); lock.recoverOtherToken(IERC20(address(token)), EVE);
    }

    function testClockCallbackCannotBeCalledByBeneficiaryAuctionOrDonor() public {
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(ALICE); lock.onPurchasedTokensReceived(100);
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(address(auction)); lock.onPurchasedTokensReceived(100);
        vm.expectRevert(BidLock.Unauthorized.selector); vm.prank(EVE); lock.onPurchasedTokensReceived(0);
        assertEq(lock.purchasedReceived(), 0);
    }

    function testCannotRecoverSaleTokenThroughOtherTokenPath() public {
        auction.claimTokens(_bidWithOutcome(lock, 100, 0));
        vm.expectRevert(BidLock.InvalidRecipient.selector); vm.prank(ALICE);
        lock.recoverOtherToken(IERC20(address(token)), ALICE);
        LaunchToken other = new LaunchToken("Other", "OTH", 50, address(lock));
        vm.prank(ALICE); lock.recoverOtherToken(IERC20(address(other)), BOB);
        assertEq(other.balanceOf(BOB), 50); assertEq(token.balanceOf(address(lock)), 100);
    }

    function testZeroRecipientsRejected() public {
        vm.expectRevert(BidLock.InvalidRecipient.selector); vm.prank(ALICE); lock.withdrawRefunds(payable(address(0)));
        vm.expectRevert(BidLock.InvalidRecipient.selector); vm.prank(ALICE); lock.withdrawTokens(address(0));
        vm.expectRevert(BidLock.InvalidRecipient.selector); vm.prank(ALICE); lock.withdrawDonatedTokens(address(0));
    }

    function testRejectedNativeTransferPreservesRefundAndAllowsRetry() public {
        uint256 id = _bidWithOutcome(lock, 0, BUDGET); lock.exitBid(id);
        LocalRejectNativeFixture reject = new LocalRejectNativeFixture();
        vm.expectRevert(BidLock.NativeTransferFailed.selector); vm.prank(ALICE);
        lock.withdrawRefunds(payable(address(reject)));
        assertEq(lock.availableRefund(), BUDGET);
        vm.prank(ALICE); assertEq(lock.withdrawRefunds(payable(BOB)), BUDGET);
    }

    function testReentrantRefundReceiverCannotWithdrawTwice() public {
        LocalReentrantBeneficiaryFixture beneficiary = new LocalReentrantBeneficiaryFixture();
        BidLock guarded = _newLock(address(beneficiary), DURATION, 0);
        beneficiary.configure(guarded);
        (bool sent,) = payable(address(guarded)).call{value: 1 ether}(""); assertTrue(sent);
        beneficiary.withdraw();
        assertFalse(beneficiary.nestedSucceeded());
        assertEq(bytes32(beneficiary.nestedError()), bytes32(BidLock.Reentrancy.selector));
        assertEq(beneficiary.received(), 1 ether); assertEq(address(guarded).balance, 0);
    }

    function testUnknownBidAndInvalidBatchCannotBeClaimedThroughWrapper() public {
        vm.expectRevert(BidLock.UnknownBid.selector); lock.claimBid(999);
        vm.expectRevert(BidLock.UnknownBid.selector); lock.exitBid(999);
        vm.expectRevert(BidLock.UnknownBid.selector); lock.exitPartiallyFilledBid(999, 0, 0);
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(BidLock.InvalidBatch.selector); lock.claimBids(empty);
        uint256[] memory excessive = new uint256[](65);
        vm.expectRevert(BidLock.InvalidBatch.selector); lock.claimBids(excessive);
    }

    function testPermissionlessBatchClaimStartsClockOnce() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _bidWithOutcome(lock, 100, 0); ids[1] = _bidWithOutcome(lock, 50, 0);
        vm.prank(EVE); lock.claimBids(ids);
        assertEq(lock.firstClaimTime(), 1000); assertEq(lock.unlockAt(), 2000);
        assertEq(lock.purchasedReceived(), 150);
    }

    function testRevertedBatchRollsBackEarlierPayoutAndClock() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _bidWithOutcome(lock, 100, 0); ids[1] = _bidWithOutcome(lock, 0, 0);
        auction.claimTokens(ids[1]);
        uint256 auctionBefore = token.balanceOf(address(auction));
        vm.expectRevert(LocalLockAuctionFixture.AlreadyClaimed.selector); lock.claimBids(ids);
        assertFalse(auction.isClaimed(ids[0])); assertEq(token.balanceOf(address(lock)), 0);
        assertEq(token.balanceOf(address(auction)), auctionBefore); assertEq(lock.firstClaimTime(), 0);
        assertEq(lock.purchasedReceived(), 0);
    }

    function testClockOverflowCallbackRollsBackTokenTransferAndClaim() public {
        uint256 id = _bidWithOutcome(lock, 100, 0);
        uint256 auctionBefore = token.balanceOf(address(auction));
        vm.warp(uint256(type(uint64).max) - DURATION + 1);
        vm.expectRevert(BidLock.InvalidAmount.selector); lock.claimBid(id);
        assertFalse(auction.isClaimed(id)); assertEq(token.balanceOf(address(lock)), 0);
        assertEq(token.balanceOf(address(auction)), auctionBefore);
        assertEq(lock.firstClaimTime(), 0); assertEq(lock.purchasedReceived(), 0);
    }

    function testConstructorRejectsWrongCurrencyOrMissingAuction() public {
        LockOption memory option = LockOption(DURATION, 15000);
        vm.expectRevert(BidLock.InvalidAuction.selector);
        new BidLock(ALICE, IContinuousClearingAuction(address(0xBAD)), 0, option, 0);
        LocalLockAuctionFixture wrongCurrency = new LocalLockAuctionFixture(address(token), address(token));
        vm.expectRevert(BidLock.InvalidAuction.selector);
        new BidLock(ALICE, IContinuousClearingAuction(address(wrongCurrency)), 0, option, 0);
        vm.expectRevert(BidLock.InvalidAuction.selector);
        new BidLock(address(0), IContinuousClearingAuction(address(auction)), 0, option, 0);
    }

    function testTokenBindingIsFactoryOnlyAndOneTime() public {
        vm.expectRevert(LaunchToken.Unauthorized.selector); vm.prank(EVE);
        token.bindAuction(address(auction), metadata);
        vm.expectRevert(LaunchToken.AlreadyBound.selector);
        token.bindAuction(address(auction), metadata);
    }

    function testTokenBindingRejectsWrongTokenAndMissingContracts() public {
        LaunchToken unbound = new LaunchToken("New", "NEW", 100, address(this));
        vm.expectRevert(LaunchToken.InvalidBinding.selector); unbound.bindAuction(address(auction), metadata);
        vm.expectRevert(LaunchToken.InvalidBinding.selector); unbound.bindAuction(address(0xBAD), metadata);
        LocalLockAuctionFixture matching = new LocalLockAuctionFixture(address(unbound), address(0));
        vm.expectRevert(LaunchToken.InvalidBinding.selector);
        unbound.bindAuction(address(matching), IBidLockFactory(address(0xBAD)));
        assertEq(unbound.auction(), address(0));
    }

    function testUnregisteredOrOtherAuctionReceiverGetsNoCallback() public {
        LocalRejectPurchasedFixture receiver = new LocalRejectPurchasedFixture();
        auction.pay(address(receiver), 10); // Unregistered: a normal ERC20 transfer.
        metadata.register(address(receiver), BidLockMetadata(ALICE, address(0xBAD), address(0), 0));
        auction.pay(address(receiver), 10); // Other auction: still no callback.
        assertEq(token.balanceOf(address(receiver)), 20);
    }

    function testOrdinaryDonationsNeverTriggerReceiverCallback() public {
        LocalRejectPurchasedFixture receiver = new LocalRejectPurchasedFixture();
        metadata.register(address(receiver), BidLockMetadata(ALICE, address(auction), address(0), 0));
        token.transfer(address(receiver), 10);
        assertEq(token.balanceOf(address(receiver)), 10);
    }

    function testRegisteredReceiverFailureRollsBackTokenTransfer() public {
        LocalRejectPurchasedFixture receiver = new LocalRejectPurchasedFixture();
        metadata.register(address(receiver), BidLockMetadata(ALICE, address(auction), address(0), 0));
        uint256 auctionBefore = token.balanceOf(address(auction));
        vm.expectRevert(LocalRejectPurchasedFixture.CallbackRefused.selector);
        auction.pay(address(receiver), 10);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(address(auction)), auctionBefore);
        assertEq(token.totalSupply(), 1_000_000);
    }

    function _newLock(address beneficiary, uint64 duration, uint64 minimumDate) internal returns (BidLock value) {
        value = new BidLock(beneficiary, IContinuousClearingAuction(address(auction)), 0, LockOption(duration, 15000), minimumDate);
        metadata.register(address(value), BidLockMetadata(beneficiary, address(auction), address(0), 0));
    }

    function _bidWithOutcome(BidLock target, uint256 payout, uint256 refund) internal returns (uint256 id) {
        vm.prank(ALICE); id = target.bid{value: BUDGET}(2 << 96, BUDGET, 0, "");
        auction.setOutcome(id, payout, refund);
    }
}
