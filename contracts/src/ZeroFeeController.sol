// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IProtocolFeeController} from "liquidity-launcher/src/interfaces/IProtocolFeeController.sol";

/// @notice This deployment takes no platform fee. There is no owner, setter or upgrade path.
/// @dev Keeping the fee immutable also makes a failed migration's later recovery deterministic.
contract ZeroFeeController is IProtocolFeeController {
    error FeesAreImmutable();

    function getProtocolFeeAmount(address, uint256) external pure returns (uint256) { return 0; }
    function protocolFeeRecipient() external view returns (address) { return address(this); }
    function getProtocolFeeBracketsForCurrency(address)
        external pure returns (ProtocolFeeBracket[] memory brackets)
    { brackets = new ProtocolFeeBracket[](0); }

    function setProtocolFeeRecipient(address) external pure { revert FeesAreImmutable(); }
    function setGlobalProtocolFeePips(uint24) external pure { revert FeesAreImmutable(); }
    function setProtocolFeeBracketsForCurrency(address, ProtocolFeeBracket[] calldata) external pure {
        revert FeesAreImmutable();
    }
    receive() external payable {}
}
