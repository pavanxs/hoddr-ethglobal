// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IPurchasedTokenReceiver {
    function onPurchasedTokensReceived(uint256 amount) external;
}
