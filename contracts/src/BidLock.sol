// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IPurchasedTokenReceiver} from "./interfaces/IPurchasedTokenReceiver.sol";
import {LockOption} from "./LaunchpadTypes.sol";

/// @notice A beneficiary's immutable CCA bid owner and purchased-token holding contract.
/// @dev Quote refunds are never locked. Receipt clock is started by the bound LaunchToken's
/// authenticated callback for a positive transfer from the exact CCA, including external claims.
/// Donated tokens cannot start or advance the clock.
contract BidLock is IPurchasedTokenReceiver {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable beneficiary;
    IContinuousClearingAuction public immutable auction;
    IERC20 public immutable token;
    uint8 public immutable lockOptionIndex;
    uint64 public immutable lockDuration;
    uint64 public immutable requestedUnlockAt;
    uint32 public immutable multiplierBps;
    uint64 public firstClaimTime;
    uint64 public unlockAt;
    uint256 public purchasedReceived;
    uint256 public purchasedReleased;

    uint256[] private _bidIds;
    mapping(uint256 bidId => bool) public ownsBid;
    uint256 private _entered;

    error Unauthorized();
    error InvalidAuction();
    error InvalidAmount();
    error InvalidRecipient();
    error UnknownBid();
    error Reentrancy();
    error NoPurchasedTokens();
    error TokensStillLocked(uint256 unlockAt);
    error NothingToWithdraw();
    error NativeTransferFailed();
    error InvalidBatch();
    event BidCreated(uint256 indexed bidId, uint128 amount, uint256 maxPriceQ96);
    event HoldingClockStarted(uint64 firstClaimTime, uint64 unlockAt, uint64 duration, uint64 minimumDate);
    event PurchasedTokensReceived(uint256 amount, uint256 totalReceived);
    event PurchasedTokensWithdrawn(address indexed recipient, uint256 amount);
    event DonationWithdrawn(address indexed recipient, uint256 amount);
    event RefundWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(
        address beneficiary_,
        IContinuousClearingAuction auction_,
        uint8 lockOptionIndex_,
        LockOption memory option,
        uint64 minimumUnlockDate
    ) {
        if (beneficiary_ == address(0) || address(auction_).code.length == 0 || auction_.currency() != address(0)) {
            revert InvalidAuction();
        }
        factory = msg.sender;
        beneficiary = beneficiary_;
        auction = auction_;
        token = IERC20(auction_.token());
        lockOptionIndex = lockOptionIndex_;
        lockDuration = option.durationSeconds;
        requestedUnlockAt = minimumUnlockDate;
        multiplierBps = option.multiplierBps;
    }

    receive() external payable {}

    function bidIds() external view returns (uint256[] memory) { return _bidIds; }
    function bidCount() external view returns (uint256) { return _bidIds.length; }
    function bidIdAt(uint256 index) external view returns (uint256) { return _bidIds[index]; }
    function availableRefund() external view returns (uint256) { return address(this).balance; }
    function purchasedOutstanding() public view returns (uint256) { return purchasedReceived - purchasedReleased; }
    function tokenBalance() external view returns (uint256) { return token.balanceOf(address(this)); }
    function canWithdrawPurchased() external view returns (bool) {
        return purchasedOutstanding() != 0 && block.timestamp >= unlockAt;
    }

    function bid(uint256 maxPriceQ96, uint128 amount, uint256 previousTickQ96, bytes calldata ensEvidence)
        external payable onlyBeneficiary nonReentrant returns (uint256 bidId)
    {
        if (amount == 0 || msg.value != amount) revert InvalidAmount();
        bidId = auction.submitBid{value: amount}(maxPriceQ96, amount, address(this), previousTickQ96, ensEvidence);
        if (ownsBid[bidId]) revert InvalidAmount();
        ownsBid[bidId] = true;
        _bidIds.push(bidId);
        emit BidCreated(bidId, amount, maxPriceQ96);
    }

    /// @notice Permissionless settlement; CCA enforces the bid's actual exit conditions.
    function exitBid(uint256 bidId) external nonReentrant {
        if (!ownsBid[bidId]) revert UnknownBid();
        auction.exitBid(bidId);
    }

    function exitPartiallyFilledBid(uint256 bidId, uint64 lastFullyFilledCheckpoint, uint64 outbidBlock)
        external nonReentrant
    {
        if (!ownsBid[bidId]) revert UnknownBid();
        auction.exitPartiallyFilledBid(bidId, lastFullyFilledCheckpoint, outbidBlock);
    }

    function claimBid(uint256 bidId) external nonReentrant {
        if (!ownsBid[bidId]) revert UnknownBid();
        auction.claimTokens(bidId);
    }

    function claimBids(uint256[] calldata ids) external nonReentrant {
        if (ids.length == 0 || ids.length > 64) revert InvalidBatch();
        for (uint256 i; i < ids.length; ++i) if (!ownsBid[ids[i]]) revert UnknownBid();
        auction.claimTokensBatch(address(this), ids);
    }

    /// @dev No external calls. Called only by this launch's fixed-supply token on exact CCA payouts.
    /// An arbitrary token donation or a zero payout does not activate the clock.
    function onPurchasedTokensReceived(uint256 amount) external {
        if (msg.sender != address(token)) revert Unauthorized();
        if (amount == 0) return;
        bool firstPayout = purchasedReceived == 0;
        purchasedReceived += amount;
        if (firstPayout) {
            if (block.timestamp > type(uint64).max - lockDuration) revert InvalidAmount();
            firstClaimTime = uint64(block.timestamp);
            uint64 durationEnd = uint64(block.timestamp) + lockDuration;
            unlockAt = durationEnd > requestedUnlockAt ? durationEnd : requestedUnlockAt;
            emit HoldingClockStarted(firstClaimTime, unlockAt, lockDuration, requestedUnlockAt);
        }
        emit PurchasedTokensReceived(amount, purchasedReceived);
    }

    function withdrawRefunds(address payable recipient) external onlyBeneficiary nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidRecipient();
        amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit RefundWithdrawn(recipient, amount);
    }

    function withdrawTokens(address recipient) external onlyBeneficiary nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (purchasedReceived == 0 || purchasedOutstanding() == 0) revert NoPurchasedTokens();
        if (block.timestamp < unlockAt) revert TokensStillLocked(unlockAt);
        amount = token.balanceOf(address(this));
        purchasedReleased = purchasedReceived;
        token.safeTransfer(recipient, amount);
        emit PurchasedTokensWithdrawn(recipient, amount);
    }

    /// @notice Recover only extra sale tokens above the authenticated, still-held CCA payouts.
    function withdrawDonatedTokens(address recipient) external onlyBeneficiary nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidRecipient();
        uint256 balance = token.balanceOf(address(this));
        uint256 outstanding = purchasedOutstanding();
        if (balance <= outstanding) revert NothingToWithdraw();
        amount = balance - outstanding;
        token.safeTransfer(recipient, amount);
        emit DonationWithdrawn(recipient, amount);
    }

    function recoverOtherToken(IERC20 other, address recipient) external onlyBeneficiary nonReentrant {
        if (address(other) == address(token) || recipient == address(0)) revert InvalidRecipient();
        other.safeTransfer(recipient, other.balanceOf(address(this)));
    }
}
