// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBidLockFactory, BidLockMetadata} from "./interfaces/IBidLockFactory.sol";
import {IPurchasedTokenReceiver} from "./interfaces/IPurchasedTokenReceiver.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";

/// @notice Fixed-supply ERC20. Only exact CCA payouts to this platform's registered wrappers
/// notify their holding clock. Normal transfers have no fee, rebase or receiver callback.
contract LaunchToken is ERC20 {
    address public immutable factory;
    address public auction;
    IBidLockFactory public wrapperFactory;

    error Unauthorized();
    error AlreadyBound();
    error InvalidBinding();
    event AuctionBound(address indexed auction, address indexed wrapperFactory);

    constructor(string memory name_, string memory symbol_, uint256 supply_, address initialHolder)
        ERC20(name_, symbol_)
    {
        factory = msg.sender;
        _mint(initialHolder, supply_);
    }

    function bindAuction(address auction_, IBidLockFactory wrapperFactory_) external {
        if (msg.sender != factory) revert Unauthorized();
        if (auction != address(0)) revert AlreadyBound();
        if (auction_.code.length == 0 || address(wrapperFactory_).code.length == 0
            || IContinuousClearingAuction(auction_).token() != address(this)) revert InvalidBinding();
        auction = auction_;
        wrapperFactory = wrapperFactory_;
        emit AuctionBound(auction_, address(wrapperFactory_));
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (amount != 0 && from != address(0) && from == auction) {
            BidLockMetadata memory meta = wrapperFactory.wrapperInfo(to);
            if (meta.beneficiary != address(0) && meta.auction == auction) {
                IPurchasedTokenReceiver(to).onPurchasedTokensReceived(amount);
            }
        }
    }
}
