// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

struct BidLockMetadata {
    address beneficiary;
    address auction;
    address hook;
    uint8 lockOptionIndex;
}

interface IBidLockFactory {
    function wrapperInfo(address wrapper) external view returns (BidLockMetadata memory);
    function wrapperFor(address auction, address beneficiary) external view returns (address);
}
