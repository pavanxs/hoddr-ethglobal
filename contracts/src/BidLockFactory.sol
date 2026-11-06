// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IBidLockFactory, BidLockMetadata} from "./interfaces/IBidLockFactory.sol";
import {IPhaseCapHook} from "./interfaces/IPhaseCapHook.sol";
import {LockOption} from "./LaunchpadTypes.sol";
import {BidLock} from "./BidLock.sol";

/// @notice One immutable holding wrapper per beneficiary and registered auction.
contract BidLockFactory is IBidLockFactory {
    address public immutable launchpadFactory;
    uint256 public constant MAX_MINIMUM_DATE_DELAY = 3650 days;
    mapping(address auction => address hook) public auctionHook;
    mapping(address auction => mapping(address beneficiary => address)) public override wrapperFor;
    mapping(address wrapper => BidLockMetadata) private _wrapperInfo;

    error Unauthorized();
    error InvalidAuction();
    error AlreadyRegistered();
    error InvalidLockOption();
    error AlreadyHasWrapper(address wrapper);
    error InvalidMinimumDate();
    event AuctionRegistered(address indexed auction, address indexed hook);
    event BidLockCreated(
        address indexed auction,
        address indexed beneficiary,
        address indexed wrapper,
        uint8 lockOptionIndex,
        uint64 durationSeconds,
        uint64 minimumUnlockDate
    );

    constructor(address factory_) {
        if (factory_ == address(0)) revert Unauthorized();
        launchpadFactory = factory_;
    }

    function wrapperInfo(address wrapper) external view override returns (BidLockMetadata memory) {
        return _wrapperInfo[wrapper];
    }

    function registerAuction(address auction, address hook) external {
        if (msg.sender != launchpadFactory) revert Unauthorized();
        if (auctionHook[auction] != address(0)) revert AlreadyRegistered();
        if (auction.code.length == 0 || hook.code.length == 0
            || address(IContinuousClearingAuction(auction).validationHook()) != hook
            || IPhaseCapHook(hook).auction() != auction || IPhaseCapHook(hook).wrapperFactory() != address(this)) {
            revert InvalidAuction();
        }
        auctionHook[auction] = hook;
        emit AuctionRegistered(auction, hook);
    }

    function createBidLock(address auction, uint256 lockOptionIndex, uint64 minimumUnlockDate)
        external returns (BidLock wrapper)
    {
        return _create(msg.sender, auction, lockOptionIndex, minimumUnlockDate);
    }

    function createBidLockFor(address beneficiary, address auction, uint256 lockOptionIndex, uint64 minimumUnlockDate)
        external returns (BidLock wrapper)
    {
        if (msg.sender != launchpadFactory) revert Unauthorized();
        return _create(beneficiary, auction, lockOptionIndex, minimumUnlockDate);
    }

    function _create(address beneficiary, address auction, uint256 lockOptionIndex, uint64 minimumUnlockDate)
        private returns (BidLock wrapper)
    {
        address hook = auctionHook[auction];
        if (beneficiary == address(0) || hook == address(0)) revert InvalidAuction();
        if (lockOptionIndex >= IPhaseCapHook(hook).lockOptionCount() || lockOptionIndex > type(uint8).max) {
            revert InvalidLockOption();
        }
        if (uint256(minimumUnlockDate) > block.timestamp + MAX_MINIMUM_DATE_DELAY) revert InvalidMinimumDate();
        address existing = wrapperFor[auction][beneficiary];
        if (existing != address(0)) {
            if (_wrapperInfo[existing].lockOptionIndex != lockOptionIndex
                || BidLock(payable(existing)).requestedUnlockAt() != minimumUnlockDate) revert AlreadyHasWrapper(existing);
            return BidLock(payable(existing));
        }
        LockOption memory option = IPhaseCapHook(hook).lockOptionAt(lockOptionIndex);
        wrapper = new BidLock(beneficiary, IContinuousClearingAuction(auction), uint8(lockOptionIndex), option, minimumUnlockDate);
        wrapperFor[auction][beneficiary] = address(wrapper);
        _wrapperInfo[address(wrapper)] = BidLockMetadata(beneficiary, auction, hook, uint8(lockOptionIndex));
        emit BidLockCreated(auction, beneficiary, address(wrapper), uint8(lockOptionIndex), option.durationSeconds, minimumUnlockDate);
    }
}
