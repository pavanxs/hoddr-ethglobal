// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IENSDomainGate} from "./interfaces/IENSDomainGate.sol";
import {IENSV2Registry, IENSVerifiableFactory} from "./interfaces/IENSV2Registry.sol";
import {ENSV2SepoliaPins} from "./libraries/ENSV2SepoliaPins.sol";

/// @notice Same-chain, current-owner admission under one immutable ENSv2 parent.
/// @dev Walks genuine forward links from the pinned global root, checking every active entry.
///      Resolver records, permissions, suffix matches, and self-reported back-links are not ownership.
///      Scope: reviewed Sepolia ENSv2 family; simple ASCII labels; at most 8 descendant levels.
contract ENSDomainGate is IENSDomainGate {
    uint256 public constant MAX_PARENT_LABELS = 8;
    uint256 public constant MAX_DESCENDANT_LABELS = 8;
    uint256 public constant MAX_LABEL_BYTES = 63;
    uint256 public constant MAX_DNS_BYTES = 255;
    uint256 public constant MAX_EVIDENCE_BYTES = 2048;
    uint8 public constant REGISTERED = 2;

    address public constant SEPOLIA_ROOT = ENSV2SepoliaPins.ROOT;
    address public constant SEPOLIA_ETH_REGISTRY = ENSV2SepoliaPins.ETH_REGISTRY;
    address public constant SEPOLIA_FACTORY = ENSV2SepoliaPins.FACTORY;
    address public constant SEPOLIA_USER_IMPLEMENTATION = ENSV2SepoliaPins.USER_IMPLEMENTATION;
    bytes32 public constant SEPOLIA_SYSTEM_CODE_HASH = ENSV2SepoliaPins.SYSTEM_CODE_HASH;
    bytes32 public constant SEPOLIA_FACTORY_CODE_HASH = ENSV2SepoliaPins.FACTORY_CODE_HASH;
    bytes32 public constant SEPOLIA_USER_CODE_HASH = ENSV2SepoliaPins.USER_CODE_HASH;

    struct TrustConfig {
        address rootRegistry;
        address ethRegistry;
        address factory;
        address userRegistryImplementation;
        bytes32 rootCodeHash;
        bytes32 ethCodeHash;
        bytes32 factoryCodeHash;
        bytes32 implementationCodeHash;
        bool localTestOnly;
    }

    enum Reason {
        Eligible,
        InvalidBeneficiary,
        InvalidEvidence,
        WrongChain,
        TrustChanged,
        InvalidLabel,
        InvalidDepth,
        NameTooLong,
        InactiveParent,
        MissingSubregistry,
        UnsupportedRegistry,
        InactiveName,
        WrongOwner
    }

    struct Eligibility {
        bool eligible;
        Reason reason;
        address registry;
        address owner;
        uint64 expiry;
        uint256 labelIndex;
        bool inParentPath;
    }

    address public immutable rootRegistry;
    address public immutable ethRegistry;
    IENSVerifiableFactory public immutable factory;
    address public immutable userRegistryImplementation;
    bytes32 public immutable rootCodeHash;
    bytes32 public immutable ethCodeHash;
    bytes32 public immutable factoryCodeHash;
    bytes32 public immutable implementationCodeHash;
    uint256 public immutable deploymentChainId;
    uint256 public immutable parentWireLength;
    bytes32 public immutable parentNamehash;
    bool public immutable localTestOnly;
    string[] private _parentLabels;

    error InvalidTrustConfiguration();
    error UnsupportedChain(uint256 chainId);
    error UnsupportedParent();
    error InvalidParentRoute(Reason reason, uint256 labelIndex);
    error EvidenceTooLarge();

    /// @param parentLabels_ Root-first labels: ["eth", "community"] for community.eth.
    /// @dev Requires the actual parent and child registry to exist at deployment.
    ///      Local fixture config is permitted only on chain 31337/1337 and is visibly labeled.
    constructor(TrustConfig memory config, string[] memory parentLabels_) {
        if (config.localTestOnly) {
            if (block.chainid != 31337 && block.chainid != 1337) revert UnsupportedChain(block.chainid);
        } else {
            if (block.chainid != 11155111) revert UnsupportedChain(block.chainid);
            if (!_isSepoliaConfiguration(config)) revert InvalidTrustConfiguration();
        }
        if (config.rootRegistry == address(0) || config.ethRegistry == address(0)
            || config.factory == address(0) || config.userRegistryImplementation == address(0)
            || config.rootRegistry == config.ethRegistry
            || config.rootRegistry == config.factory || config.ethRegistry == config.factory
            || config.rootRegistry == config.userRegistryImplementation
            || config.ethRegistry == config.userRegistryImplementation
            || config.factory == config.userRegistryImplementation) {
            revert InvalidTrustConfiguration();
        }
        rootRegistry = config.rootRegistry;
        ethRegistry = config.ethRegistry;
        factory = IENSVerifiableFactory(config.factory);
        userRegistryImplementation = config.userRegistryImplementation;
        rootCodeHash = config.rootCodeHash;
        ethCodeHash = config.ethCodeHash;
        factoryCodeHash = config.factoryCodeHash;
        implementationCodeHash = config.implementationCodeHash;
        deploymentChainId = block.chainid;
        localTestOnly = config.localTestOnly;
        if (!_trustIntact()) revert InvalidTrustConfiguration();

        uint256 count = parentLabels_.length;
        if (count < 2 || count > MAX_PARENT_LABELS || keccak256(bytes(parentLabels_[0])) != keccak256("eth")) {
            revert UnsupportedParent();
        }
        uint256 wireLength = 1; // DNS terminal zero.
        bytes32 node;
        for (uint256 i; i < count; ++i) {
            if (!_validLabel(bytes(parentLabels_[i]))) revert UnsupportedParent();
            wireLength += bytes(parentLabels_[i]).length + 1;
            node = keccak256(abi.encodePacked(node, keccak256(bytes(parentLabels_[i]))));
            _parentLabels.push(parentLabels_[i]);
        }
        // Reserve room for at least one one-byte descendant label and its length byte.
        if (wireLength + 2 > MAX_DNS_BYTES) revert UnsupportedParent();
        parentWireLength = wireLength;
        parentNamehash = node;
        Eligibility memory route = _resolveParent();
        if (route.reason != Reason.Eligible) revert InvalidParentRoute(route.reason, route.labelIndex);
    }

    /// @notice Standard cap-hook entry point. Malformed evidence and failed reads never approve.
    function isEligible(address beneficiary, bytes calldata evidence) external view override returns (bool) {
        if (beneficiary == address(0) || evidence.length > MAX_EVIDENCE_BYTES) return false;
        try this.inspect(beneficiary, evidence) returns (Eligibility memory result) {
            return result.eligible;
        } catch {
            return false;
        }
    }

    /// @notice Detailed read for UI/preflight. Malformed ABI may revert; isEligible catches it.
    function inspect(address beneficiary, bytes calldata evidence) external view returns (Eligibility memory result) {
        if (beneficiary == address(0)) return _failure(Reason.InvalidBeneficiary);
        if (block.chainid != deploymentChainId) return _failure(Reason.WrongChain);
        if (!_trustIntact()) return _failure(Reason.TrustChanged);
        if (evidence.length > MAX_EVIDENCE_BYTES) revert EvidenceTooLarge();
        string[] memory labels = abi.decode(evidence, (string[]));
        if (keccak256(evidence) != keccak256(abi.encode(labels))) return _failure(Reason.InvalidEvidence);
        uint256 count = labels.length;
        if (count == 0 || count > MAX_DESCENDANT_LABELS) return _failure(Reason.InvalidDepth);
        uint256 wireLength = parentWireLength;
        for (uint256 i; i < count; ++i) {
            if (!_validLabel(bytes(labels[i]))) {
                result = _failure(Reason.InvalidLabel);
                result.labelIndex = i;
                return result;
            }
            wireLength += bytes(labels[i]).length + 1;
        }
        if (wireLength > MAX_DNS_BYTES) return _failure(Reason.NameTooLong);

        result = _resolveParent();
        if (result.reason != Reason.Eligible) return result;
        address registry = result.registry;
        for (uint256 i; i < count; ++i) {
            (bool active, address owner, uint64 expiry) = _activeEntry(registry, labels[i]);
            result = Eligibility(false, Reason.InactiveName, registry, owner, expiry, i, false);
            if (!active) return result;
            if (i + 1 == count) {
                result.eligible = owner == beneficiary;
                result.reason = result.eligible ? Reason.Eligible : Reason.WrongOwner;
                return result;
            }
            address child = IENSV2Registry(registry).getSubregistry(labels[i]);
            if (child == address(0)) { result.reason = Reason.MissingSubregistry; return result; }
            if (!_supportedUserRegistry(child)) { result.reason = Reason.UnsupportedRegistry; return result; }
            registry = child;
        }
    }

    function parentLabels() external view returns (string[] memory) { return _parentLabels; }

    /// @notice Whether the configured parent route is currently usable; not a participant check.
    function inspectParent() external view returns (Eligibility memory result) {
        if (block.chainid != deploymentChainId) return _failure(Reason.WrongChain);
        if (!_trustIntact()) return _failure(Reason.TrustChanged);
        result = _resolveParent();
        result.eligible = result.reason == Reason.Eligible;
    }

    function parentDomain() external view returns (string memory name) {
        uint256 count = _parentLabels.length;
        name = _parentLabels[count - 1];
        while (--count != 0) name = string.concat(name, ".", _parentLabels[count - 1]);
    }

    /// @notice Public constructor input for the reviewed Sepolia deployment.
    function sepoliaTrustConfig() external pure returns (TrustConfig memory) {
        return TrustConfig(
            SEPOLIA_ROOT, SEPOLIA_ETH_REGISTRY, SEPOLIA_FACTORY, SEPOLIA_USER_IMPLEMENTATION,
            SEPOLIA_SYSTEM_CODE_HASH, SEPOLIA_SYSTEM_CODE_HASH, SEPOLIA_FACTORY_CODE_HASH,
            SEPOLIA_USER_CODE_HASH, false
        );
    }

    function _resolveParent() private view returns (Eligibility memory result) {
        address registry = rootRegistry;
        uint256 count = _parentLabels.length;
        for (uint256 i; i < count; ++i) {
            (bool active, address owner, uint64 expiry) = _activeEntry(registry, _parentLabels[i]);
            result = Eligibility(false, Reason.InactiveParent, registry, owner, expiry, i, true);
            if (!active) return result;
            address child = IENSV2Registry(registry).getSubregistry(_parentLabels[i]);
            if (child == address(0)) { result.reason = Reason.MissingSubregistry; return result; }
            bool supported = i == 0 ? child == ethRegistry : _supportedUserRegistry(child);
            if (!supported) { result.reason = Reason.UnsupportedRegistry; return result; }
            registry = child;
        }
        result.registry = registry;
        result.reason = Reason.Eligible;
    }

    function _activeEntry(address registry, string memory label)
        private view returns (bool active, address owner, uint64 expiry)
    {
        uint256 id = uint256(keccak256(bytes(label)));
        IENSV2Registry.State memory state = IENSV2Registry(registry).getState(id);
        owner = IENSV2Registry(registry).getOwner(id);
        expiry = state.expiry;
        active = state.status == REGISTERED && expiry > block.timestamp
            && owner != address(0) && owner == state.latestOwner;
    }

    function _supportedUserRegistry(address registry) private view returns (bool) {
        if (registry == address(0) || registry == rootRegistry || registry == ethRegistry
            || registry == address(factory) || registry == userRegistryImplementation || registry.code.length == 0) {
            return false;
        }
        try factory.verifyContract(registry) returns (address implementation) {
            return implementation == userRegistryImplementation;
        } catch { return false; }
    }

    function _trustIntact() private view returns (bool) {
        return rootRegistry.code.length != 0 && ethRegistry.code.length != 0
            && address(factory).code.length != 0 && userRegistryImplementation.code.length != 0
            && rootRegistry.codehash == rootCodeHash && ethRegistry.codehash == ethCodeHash
            && address(factory).codehash == factoryCodeHash
            && userRegistryImplementation.codehash == implementationCodeHash;
    }

    function _isSepoliaConfiguration(TrustConfig memory config) private pure returns (bool) {
        return config.rootRegistry == SEPOLIA_ROOT && config.ethRegistry == SEPOLIA_ETH_REGISTRY
            && config.factory == SEPOLIA_FACTORY && config.userRegistryImplementation == SEPOLIA_USER_IMPLEMENTATION
            && config.rootCodeHash == SEPOLIA_SYSTEM_CODE_HASH && config.ethCodeHash == SEPOLIA_SYSTEM_CODE_HASH
            && config.factoryCodeHash == SEPOLIA_FACTORY_CODE_HASH
            && config.implementationCodeHash == SEPOLIA_USER_CODE_HASH;
    }

    function _validLabel(bytes memory label) private pure returns (bool) {
        uint256 length = label.length;
        if (length == 0 || length > MAX_LABEL_BYTES || label[0] == "-" || label[length - 1] == "-") return false;
        // Reject IDNA/punycode-style reserved double-hyphen position; no silent Unicode reinterpretation.
        if (length >= 4 && label[2] == "-" && label[3] == "-") return false;
        for (uint256 i; i < length; ++i) {
            bytes1 c = label[i];
            if (!(c >= "a" && c <= "z") && !(c >= "0" && c <= "9") && c != "-") return false;
        }
        return true;
    }

    function _failure(Reason reason) private pure returns (Eligibility memory result) {
        result.reason = reason;
    }
}
