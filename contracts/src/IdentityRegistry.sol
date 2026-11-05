// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IWorldIDV3} from "./interfaces/IWorldIDV3.sol";

/// @notice Permanent wallet-to-human bindings checked by the actual World ID v3 Orb Router.
/// @dev Multiple wallets may prove the same nullifier, but each needs its own wallet-bound proof.
///      No administrator, server ticket, removal, rebind, or verification fallback exists.
///      Verification records a valid enrollment at a point in time; it is not a live credential feed.
contract IdentityRegistry is IIdentityRegistry {
    uint256 public constant GROUP_ID = 1;
    uint256 public constant MAX_WALLETS_PER_IDENTITY = 32;
    uint256 public constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
    bytes32 public constant PROVIDER_ID = keccak256("WORLD_ID_V3_ORB");
    address public constant SEPOLIA_WORLD_ID_ROUTER = 0x469449f251692E0779667583026b5A1E99512157;

    IWorldIDV3 public immutable worldIdRouter;
    uint256 public immutable deploymentChainId;
    uint256 public immutable externalNullifierHash;
    bool public immutable localTestOnly;
    string public appId;
    string public action;

    mapping(address beneficiary => bytes32 identity) public override identityOf;
    mapping(address beneficiary => uint64 timestamp) public verifiedAt;
    mapping(bytes32 identity => address[] wallets) private _wallets;

    error InvalidConfiguration();
    error UnsupportedChain(uint256 chainId);
    error UnexpectedRouter(address router);
    error WrongChain(uint256 expected, uint256 actual);
    error BeneficiaryMustCall(address beneficiary, address caller);
    error WalletAlreadyBound(address beneficiary, bytes32 identity);
    error InvalidNullifier();
    error InvalidRoot();
    error IdentityWalletLimit(bytes32 identity);

    event WalletBound(
        address indexed beneficiary,
        bytes32 indexed identity,
        uint256 indexed nullifierHash,
        uint256 signalHash
    );

    /// @param localTestOnly_ True only on chain 31337 or 1337, for explicit mock-router fixtures.
    /// @dev Real mode currently supports the reviewed Sepolia Router only. Other chains fail closed.
    constructor(address router_, string memory appId_, string memory action_, bool localTestOnly_) {
        if (router_.code.length == 0 || bytes(appId_).length < 5 || bytes(appId_).length > 128
            || bytes(action_).length == 0 || bytes(action_).length > 256) {
            revert InvalidConfiguration();
        }
        bytes memory appBytes = bytes(appId_);
        if (appBytes[0] != "a" || appBytes[1] != "p" || appBytes[2] != "p" || appBytes[3] != "_") {
            revert InvalidConfiguration();
        }
        if (localTestOnly_) {
            if (block.chainid != 31337 && block.chainid != 1337) revert UnsupportedChain(block.chainid);
        } else {
            if (block.chainid != 11155111) revert UnsupportedChain(block.chainid);
            if (router_ != SEPOLIA_WORLD_ID_ROUTER) revert UnexpectedRouter(router_);
        }
        worldIdRouter = IWorldIDV3(router_);
        deploymentChainId = block.chainid;
        localTestOnly = localTestOnly_;
        appId = appId_;
        action = action_;

        // Official v3 formula: hashToField(abi.encodePacked(hashToField(appId), action)).
        // This must match the app_id/action used by IDKit; callers cannot supply a different value.
        externalNullifierHash = uint256(keccak256(abi.encodePacked(
            uint256(keccak256(bytes(appId_))) >> 8, action_
        ))) >> 8;
    }

    /// @notice Pass this exact non-hex UTF-8 string to IDKit.orbLegacy({ signal }).
    /// @dev It binds the proof to the deployed registry, network, and authenticated beneficiary.
    function expectedSignal(address beneficiary) public view returns (string memory) {
        return string.concat(
            "hoddr-launchpad-world-v3:", _decimal(deploymentChainId), ":", _hexAddress(address(this)),
            ":", _hexAddress(beneficiary)
        );
    }

    function expectedSignalHash(address beneficiary) public view returns (uint256) {
        return uint256(keccak256(bytes(expectedSignal(beneficiary)))) >> 8;
    }

    /// @notice Stable across linked wallets for this provider and app/action scope.
    function identityKey(uint256 nullifierHash) public view returns (bytes32) {
        return keccak256(abi.encode(PROVIDER_ID, externalNullifierHash, nullifierHash));
    }

    /// @notice Enroll the calling wallet using an actual Router-verified, wallet-bound proof.
    /// @dev Enrollment is not a financial claim. Reuse of a human nullifier on another wallet is
    ///      intentional; replay on the same wallet and switching its identity are both forbidden.
    function verifyAndBind(
        address beneficiary,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external returns (bytes32 identity) {
        if (block.chainid != deploymentChainId) revert WrongChain(deploymentChainId, block.chainid);
        if (beneficiary == address(0) || msg.sender != beneficiary) {
            revert BeneficiaryMustCall(beneficiary, msg.sender);
        }
        bytes32 existing = identityOf[beneficiary];
        if (existing != bytes32(0)) revert WalletAlreadyBound(beneficiary, existing);
        if (nullifierHash == 0 || nullifierHash >= SNARK_SCALAR_FIELD) revert InvalidNullifier();
        if (root == 0 || root >= SNARK_SCALAR_FIELD) revert InvalidRoot();
        identity = identityKey(nullifierHash);
        if (identity == bytes32(0)) revert InvalidNullifier();
        if (_wallets[identity].length >= MAX_WALLETS_PER_IDENTITY) revert IdentityWalletLimit(identity);

        uint256 signalHash = expectedSignalHash(beneficiary);
        worldIdRouter.verifyProof(root, GROUP_ID, signalHash, nullifierHash, externalNullifierHash, proof);

        // All state changes occur after the verifier returns successfully. The view ABI uses STATICCALL.
        identityOf[beneficiary] = identity;
        verifiedAt[beneficiary] = uint64(block.timestamp);
        _wallets[identity].push(beneficiary);
        emit WalletBound(beneficiary, identity, nullifierHash, signalHash);
    }

    function walletCount(bytes32 identity) external view override returns (uint256) {
        return _wallets[identity].length;
    }

    function walletAt(bytes32 identity, uint256 index) external view override returns (address) {
        return _wallets[identity][index];
    }

    /// @notice Convenience read; the result is bounded to MAX_WALLETS_PER_IDENTITY.
    function walletsOf(bytes32 identity) external view returns (address[] memory) {
        return _wallets[identity];
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        uint256 rest = value;
        while (rest != 0) { ++digits; rest /= 10; }
        bytes memory text = new bytes(digits);
        while (value != 0) {
            text[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(text);
    }

    function _hexAddress(address account) private pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory text = new bytes(42);
        text[0] = "0";
        text[1] = "x";
        uint160 value = uint160(account);
        for (uint256 i; i < 40; ++i) {
            text[41 - i] = alphabet[value & 0xf];
            value >>= 4;
        }
        return string(text);
    }
}
