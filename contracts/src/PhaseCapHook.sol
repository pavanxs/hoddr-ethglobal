// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BlockNumberish} from "blocknumberish/src/BlockNumberish.sol";
import {IValidationHook} from "continuous-clearing-auction/interfaces/IValidationHook.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IENSDomainGate} from "./interfaces/IENSDomainGate.sol";
import {IBidLockFactory, BidLockMetadata} from "./interfaces/IBidLockFactory.sol";
import {PhaseConfig, LockOption, AllowancePreview} from "./LaunchpadTypes.sol";

/// @notice CCA admission rules. Counts gross committed bid budgets, never credits refunds.
/// @dev Every verified allowance is recomputed from all permanently linked accounts. This includes
/// budgets committed before a wallet enrolled, so changing identity status cannot reset spending.
/// The weakest duration commitment among an identity's used wrappers applies auction-wide.
contract PhaseCapHook is IValidationHook, BlockNumberish {
    uint256 public constant MAX_PHASES = 16;
    uint256 public constant MAX_LOCK_OPTIONS = 8;
    uint256 public constant MAX_LINKED_WALLETS = 32;
    uint256 public constant MAX_LOCK_DURATION = 3650 days;
    uint32 public constant BPS = 10_000;
    uint32 public constant MAX_MULTIPLIER_BPS = 100_000;

    address public immutable launchpadFactory;
    address public immutable wrapperFactory;
    IIdentityRegistry public immutable identityRegistry;
    address public auction;

    PhaseConfig[] private _phases;
    LockOption[] private _lockOptions;
    mapping(address beneficiary => mapping(uint256 phaseIndex => uint256)) public accountCommitted;
    mapping(address beneficiary => bool) public hasCommitment;
    mapping(address beneficiary => uint8) public committedLockOption;

    error Unauthorized();
    error InvalidConfiguration();
    error AuctionAlreadyBound();
    error AuctionNotBound();
    error AuctionMismatch();
    error InactivePhase();
    error InvalidWrapper();
    error HumanVerificationRequired();
    error ENSNameRequired();
    error BidBelowMinimum(uint256 minimum, uint256 actual);
    error CapExceeded(uint256 cap, uint256 committed, uint256 requested);
    error InvalidIdentityRegistry();
    error EvidenceTooLarge();
    error LockOptionMismatch();

    event AuctionBound(address indexed auction);
    event BudgetCommitted(
        address indexed beneficiary,
        bytes32 indexed identity,
        uint256 indexed phaseIndex,
        address wrapper,
        uint128 amount,
        uint256 identityCommitted,
        uint256 currentCap,
        uint32 effectiveMultiplierBps
    );

    constructor(
        address factory_,
        address wrapperFactory_,
        IIdentityRegistry identityRegistry_,
        PhaseConfig[] memory phases_,
        LockOption[] memory lockOptions_
    ) {
        if (factory_ == address(0) || wrapperFactory_.code.length == 0) revert InvalidConfiguration();
        if (address(identityRegistry_) != address(0) && address(identityRegistry_).code.length == 0) {
            revert InvalidConfiguration();
        }
        if (phases_.length == 0 || phases_.length > MAX_PHASES) revert InvalidConfiguration();
        if (lockOptions_.length == 0 || lockOptions_.length > MAX_LOCK_OPTIONS) revert InvalidConfiguration();
        if (lockOptions_[0].durationSeconds != 0 || lockOptions_[0].multiplierBps != BPS) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < lockOptions_.length; ++i) {
            LockOption memory option = lockOptions_[i];
            if (option.durationSeconds > MAX_LOCK_DURATION || option.multiplierBps < BPS
                || option.multiplierBps > MAX_MULTIPLIER_BPS) revert InvalidConfiguration();
            if (i != 0 && (option.durationSeconds <= lockOptions_[i - 1].durationSeconds
                || option.multiplierBps < lockOptions_[i - 1].multiplierBps)) revert InvalidConfiguration();
            _lockOptions.push(option);
        }
        for (uint256 i; i < phases_.length; ++i) {
            PhaseConfig memory phase = phases_[i];
            if (phase.startBlock == 0 || phase.endBlock <= phase.startBlock || phase.minimumBid == 0
                || phase.baseCapEnd < phase.baseCapStart || phase.verifiedCapEnd < phase.verifiedCapStart
                || phase.verifiedCapStart < phase.baseCapStart || phase.verifiedCapEnd < phase.baseCapEnd) {
                revert InvalidConfiguration();
            }
            if (i != 0 && phase.startBlock != phases_[i - 1].endBlock) revert InvalidConfiguration();
            if (phase.verifiedOnly && address(identityRegistry_) == address(0)) revert InvalidConfiguration();
            if (phase.ensGate != address(0) && phase.ensGate.code.length == 0) revert InvalidConfiguration();
            if (!phase.verifiedOnly && phase.baseCapEnd < phase.minimumBid) revert InvalidConfiguration();
            if (phase.verifiedCapEnd < phase.minimumBid) revert InvalidConfiguration();
            _phases.push(phase);
        }
        launchpadFactory = factory_;
        wrapperFactory = wrapperFactory_;
        identityRegistry = identityRegistry_;
    }

    function bindAuction(address auction_) external {
        if (msg.sender != launchpadFactory) revert Unauthorized();
        if (auction != address(0)) revert AuctionAlreadyBound();
        if (auction_.code.length == 0) revert AuctionMismatch();
        IContinuousClearingAuction candidate = IContinuousClearingAuction(auction_);
        if (address(candidate.validationHook()) != address(this) || candidate.currency() != address(0)
            || candidate.startBlock() != _phases[0].startBlock
            || candidate.endBlock() != _phases[_phases.length - 1].endBlock) revert AuctionMismatch();
        auction = auction_;
        emit AuctionBound(auction_);
    }

    function phaseCount() external view returns (uint256) { return _phases.length; }
    function phaseAt(uint256 index) external view returns (PhaseConfig memory) { return _phases[index]; }
    function phases() external view returns (PhaseConfig[] memory) { return _phases; }
    function lockOptionCount() external view returns (uint256) { return _lockOptions.length; }
    function lockOptionAt(uint256 index) external view returns (LockOption memory) { return _lockOptions[index]; }
    function lockOptions() external view returns (LockOption[] memory) { return _lockOptions; }
    function currentBlock() external view returns (uint256) { return _getBlockNumberish(); }

    /// @notice Before start returns the first phase; after end the last phase, with active=false.
    function currentPhase() public view returns (uint256 index, bool active) {
        uint256 number = _getBlockNumberish();
        for (uint256 i; i < _phases.length; ++i) {
            if (number < _phases[i].endBlock) return (i, number >= _phases[i].startBlock);
        }
        return (_phases.length - 1, false);
    }

    function preview(address beneficiary, uint256 proposedLockOption)
        public view returns (AllowancePreview memory result)
    {
        (uint256 index,) = currentPhase();
        return _preview(beneficiary, index, proposedLockOption);
    }

    function previewPhase(address beneficiary, uint256 phaseIndex, uint256 proposedLockOption)
        external view returns (AllowancePreview memory result)
    {
        return _preview(beneficiary, phaseIndex, proposedLockOption);
    }

    /// @notice Useful before paying gas; admission always repeats these checks in validate().
    function previewWithEvidence(address beneficiary, uint256 proposedLockOption, bytes calldata evidence)
        external view returns (AllowancePreview memory result, bool ensEligible, bool eligible)
    {
        result = preview(beneficiary, proposedLockOption);
        address gate = _phases[result.phaseIndex].ensGate;
        ensEligible = gate == address(0);
        if (!ensEligible && evidence.length <= 4096) {
            try IENSDomainGate(gate).isEligible(beneficiary, evidence) returns (bool ok) { ensEligible = ok; }
            catch { ensEligible = false; }
        }
        eligible = result.active && result.identityAllowed && ensEligible && result.remaining >= result.minimumBid;
    }

    function validate(uint256, uint128 amount, address owner, address sender, bytes calldata hookData) external {
        if (auction == address(0)) revert AuctionNotBound();
        if (msg.sender != auction) revert Unauthorized();
        if (sender != owner) revert InvalidWrapper();
        if (hookData.length > 4096) revert EvidenceTooLarge();

        BidLockMetadata memory meta = IBidLockFactory(wrapperFactory).wrapperInfo(owner);
        if (meta.beneficiary == address(0) || meta.auction != auction || meta.hook != address(this)
            || IBidLockFactory(wrapperFactory).wrapperFor(auction, meta.beneficiary) != owner) revert InvalidWrapper();
        if (hasCommitment[meta.beneficiary] && committedLockOption[meta.beneficiary] != meta.lockOptionIndex) {
            revert LockOptionMismatch();
        }

        AllowancePreview memory result = preview(meta.beneficiary, meta.lockOptionIndex);
        if (!result.active) revert InactivePhase();
        if (!result.identityAllowed) revert HumanVerificationRequired();
        if (amount < result.minimumBid) revert BidBelowMinimum(result.minimumBid, amount);
        address gate = _phases[result.phaseIndex].ensGate;
        if (gate != address(0) && !IENSDomainGate(gate).isEligible(meta.beneficiary, hookData)) revert ENSNameRequired();
        if (result.committed + uint256(amount) > result.cap) {
            revert CapExceeded(result.cap, result.committed, amount);
        }

        hasCommitment[meta.beneficiary] = true;
        committedLockOption[meta.beneficiary] = meta.lockOptionIndex;
        accountCommitted[meta.beneficiary][result.phaseIndex] += uint256(amount);
        emit BudgetCommitted(
            meta.beneficiary, result.identity, result.phaseIndex, owner, amount,
            result.committed + uint256(amount), result.cap, result.effectiveMultiplierBps
        );
    }

    function _preview(address beneficiary, uint256 phaseIndex, uint256 proposedLockOption)
        private view returns (AllowancePreview memory result)
    {
        if (beneficiary == address(0) || proposedLockOption >= _lockOptions.length) revert InvalidConfiguration();
        PhaseConfig storage phase = _phases[phaseIndex];
        result.phaseIndex = phaseIndex;
        result.currentBlock = _getBlockNumberish();
        result.active = result.currentBlock >= phase.startBlock && result.currentBlock < phase.endBlock;
        result.wrapper = auction == address(0) ? address(0) : IBidLockFactory(wrapperFactory).wrapperFor(auction, beneficiary);
        uint256 optionIndex = proposedLockOption;
        if (result.wrapper != address(0)) {
            BidLockMetadata memory meta = IBidLockFactory(wrapperFactory).wrapperInfo(result.wrapper);
            if (meta.beneficiary != beneficiary || meta.auction != auction || meta.hook != address(this)) {
                revert InvalidWrapper();
            }
            optionIndex = meta.lockOptionIndex;
        }
        if (optionIndex >= _lockOptions.length) revert InvalidConfiguration();
        result.identity = address(identityRegistry) == address(0) ? bytes32(0) : identityRegistry.identityOf(beneficiary);
        result.verified = result.identity != bytes32(0);
        result.identityRequired = phase.verifiedOnly;
        result.identityAllowed = !phase.verifiedOnly || result.verified;
        result.ensRequired = phase.ensGate != address(0);
        result.accountCommitted = accountCommitted[beneficiary][phaseIndex];
        (result.committed, result.effectiveLockOptionIndex) =
            _aggregate(beneficiary, result.identity, phaseIndex, optionIndex);
        result.effectiveMultiplierBps = _lockOptions[result.effectiveLockOptionIndex].multiplierBps;
        uint256 start = result.verified ? phase.verifiedCapStart : phase.baseCapStart;
        uint256 end = result.verified ? phase.verifiedCapEnd : phase.baseCapEnd;
        uint256 base = _ramp(start, end, phase.startBlock, phase.endBlock, result.currentBlock);
        result.cap = base * uint256(result.effectiveMultiplierBps) / BPS;
        result.remaining = result.cap > result.committed ? result.cap - result.committed : 0;
        result.minimumBid = phase.minimumBid;
    }

    function _aggregate(address beneficiary, bytes32 identity, uint256 phaseIndex, uint256 proposedOption)
        private view returns (uint256 spent, uint256 effectiveOption)
    {
        effectiveOption = proposedOption;
        if (identity == bytes32(0)) {
            spent = accountCommitted[beneficiary][phaseIndex];
            if (hasCommitment[beneficiary] && committedLockOption[beneficiary] < effectiveOption) {
                effectiveOption = committedLockOption[beneficiary];
            }
            return (spent, effectiveOption);
        }
        uint256 count = identityRegistry.walletCount(identity);
        if (count == 0 || count > MAX_LINKED_WALLETS) revert InvalidIdentityRegistry();
        bool found;
        for (uint256 i; i < count; ++i) {
            address account = identityRegistry.walletAt(identity, i);
            if (account == address(0) || identityRegistry.identityOf(account) != identity) revert InvalidIdentityRegistry();
            if (account == beneficiary) found = true;
            spent += accountCommitted[account][phaseIndex];
            if (hasCommitment[account] && committedLockOption[account] < effectiveOption) {
                effectiveOption = committedLockOption[account];
            }
        }
        if (!found) revert InvalidIdentityRegistry();
    }

    function _ramp(uint256 from, uint256 to, uint64 start, uint64 end, uint256 number)
        private pure returns (uint256)
    {
        if (end - start == 1 || number >= uint256(end) - 1) return to;
        if (number <= start) return from;
        return from + (to - from) * (number - start) / (uint256(end) - start - 1);
    }
}
