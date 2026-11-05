// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ENSDomainGate} from "../src/ENSDomainGate.sol";
import {IENSV2Registry} from "../src/interfaces/IENSV2Registry.sol";
import {IdentityENSTestBase} from "./helpers/IdentityENSTestBase.sol";
import {
    LocalENSRegistryFixture, LocalENSFactoryFixture, LocalENSImplementationFixture
} from "./mocks/LocalENSFixtures.sol";

contract ENSDomainGateTest is IdentityENSTestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ADMIN = address(0xAD01);
    address internal constant TEAM_OWNER = address(0x7EA0);
    uint64 internal constant EXPIRY = 2000;
    LocalENSRegistryFixture internal root;
    LocalENSRegistryFixture internal eth;
    LocalENSRegistryFixture internal community;
    LocalENSRegistryFixture internal team;
    LocalENSFactoryFixture internal factory;
    LocalENSImplementationFixture internal implementation;
    ENSDomainGate internal gate;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1000);
        root = new LocalENSRegistryFixture();
        eth = new LocalENSRegistryFixture();
        factory = new LocalENSFactoryFixture();
        implementation = new LocalENSImplementationFixture();
        community = _newVerifiedRegistry();
        team = _newVerifiedRegistry();
        root.setName("eth", ADMIN, type(uint64).max, address(eth));
        eth.setName("community", ADMIN, EXPIRY, address(community));
        community.setName("alice", ALICE, EXPIRY, address(0));
        community.setName("team", TEAM_OWNER, EXPIRY, address(team));
        team.setName("alice", ALICE, EXPIRY, address(0));
        gate = new ENSDomainGate(_config(), _parent());
    }

    function testConfiguredParentAndNamehashAreExplicit() public view {
        assertEq(gate.parentDomain(), "community.eth");
        assertEq(gate.parentNamehash(), 0x220302cfbfda77f912157d62bd2a0d4553d6d73e677960d357c09235621436f8);
        assertEq(gate.parentWireLength(), 15);
        assertTrue(gate.localTestOnly());
        string[] memory path = gate.parentLabels();
        assertEq(path.length, 2);
        assertEq(path[0], "eth");
        assertEq(path[1], "community");
    }

    function testActiveDirectDescendantOwnerQualifies() public view {
        assertTrue(gate.isEligible(ALICE, _one("alice")));
        ENSDomainGate.Eligibility memory result = gate.inspect(ALICE, _one("alice"));
        assertTrue(result.eligible);
        assertEq(result.owner, ALICE);
        assertEq(result.registry, address(community));
        assertEq(result.expiry, EXPIRY);
    }

    function testActiveNestedDescendantOwnerQualifies() public view {
        assertTrue(gate.isEligible(ALICE, _two("team", "alice")));
        ENSDomainGate.Eligibility memory result = gate.inspect(ALICE, _two("team", "alice"));
        assertEq(result.registry, address(team));
        assertEq(result.labelIndex, 1);
        assertFalse(result.inParentPath);
    }

    function testConfiguredNestedParentWorks() public {
        string[] memory parent = new string[](3);
        parent[0] = "eth"; parent[1] = "community"; parent[2] = "team";
        ENSDomainGate nestedGate = new ENSDomainGate(_config(), parent);
        assertEq(nestedGate.parentDomain(), "team.community.eth");
        assertTrue(nestedGate.isEligible(ALICE, _one("alice")));
    }

    function testWrongOwnerDoesNotQualify() public view {
        assertFalse(gate.isEligible(BOB, _one("alice")));
        _reason(BOB, _one("alice"), ENSDomainGate.Reason.WrongOwner);
    }

    function testParentOwnerIsNotAutomaticallyDescendantOwner() public view {
        assertFalse(gate.isEligible(ADMIN, _one("alice")));
        assertFalse(gate.isEligible(TEAM_OWNER, _two("team", "alice")));
    }

    function testTransferTakesEffectImmediately() public {
        community.transferName("alice", BOB);
        assertFalse(gate.isEligible(ALICE, _one("alice")));
        assertTrue(gate.isEligible(BOB, _one("alice")));
    }

    function testNestedTransferTakesEffectImmediately() public {
        team.transferName("alice", BOB);
        assertFalse(gate.isEligible(ALICE, _two("team", "alice")));
        assertTrue(gate.isEligible(BOB, _two("team", "alice")));
    }

    function testAddressRecordAndRenewalRoleAreNotOwnership() public {
        community.transferName("alice", BOB);
        community.setAddressRecord("alice", ALICE);
        community.setRenewalPermission("alice", ALICE, true);
        assertFalse(gate.isEligible(ALICE, _one("alice")));
        assertTrue(gate.isEligible(BOB, _one("alice")));
    }

    function testLeafExpiresAtExactEqualityEvenWithHistoricalOwner() public {
        // Keep ancestors active to isolate the leaf boundary.
        eth.setExpiry("community", EXPIRY + 1000);
        vm.warp(EXPIRY - 1);
        assertTrue(gate.isEligible(ALICE, _one("alice")));
        vm.warp(EXPIRY);
        assertFalse(gate.isEligible(ALICE, _one("alice")));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.InactiveName);
        IENSV2Registry.State memory state = community.getState(uint256(keccak256("alice")));
        assertEq(state.latestOwner, ALICE);
        assertEq(community.getOwner(uint256(keccak256("alice"))), address(0));
    }

    function testExpiredIntermediateNameBlocksActiveLeaf() public {
        eth.setExpiry("community", EXPIRY + 1000);
        team.setExpiry("alice", EXPIRY + 1000);
        vm.warp(EXPIRY);
        assertFalse(gate.isEligible(ALICE, _two("team", "alice")));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.InactiveName);
    }

    function testExpiredConfiguredParentBlocksActiveDescendant() public {
        community.setExpiry("alice", EXPIRY + 1000);
        vm.warp(EXPIRY);
        assertFalse(gate.isEligible(ALICE, _one("alice")));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.InactiveParent);
    }

    function testExpiredGlobalEthEntryBlocksRoute() public {
        root.setExpiry("eth", uint64(block.timestamp));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.InactiveParent);
    }

    function testReservedAndUnregisteredNamesDoNotQualify() public {
        community.setName("reserved", address(0), EXPIRY, address(0));
        _reason(ALICE, _one("reserved"), ENSDomainGate.Reason.InactiveName);
        _reason(ALICE, _one("absent"), ENSDomainGate.Reason.InactiveName);
        community.setExpiry("alice", uint64(block.timestamp));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.InactiveName);
    }

    function testMissingIntermediateChildBlocksRoute() public {
        community.setChild("team", address(0));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.MissingSubregistry);
    }

    function testDisconnectedConfiguredParentBlocksRoute() public {
        eth.setChild("community", address(0));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.MissingSubregistry);
    }

    function testCallerSuppliedRegistryIsNotAcceptedAsEvidence() public view {
        assertFalse(gate.isEligible(ALICE, abi.encode(address(team), "alice")));
        assertFalse(gate.isEligible(ALICE, abi.encode(address(community))));
    }

    function testForgedRegistryAndParentClaimRejected() public {
        LocalENSRegistryFixture forged = new LocalENSRegistryFixture();
        forged.setName("alice", ALICE, EXPIRY, address(0));
        forged.setClaimedParent(address(community), "team");
        community.setChild("team", address(forged));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.UnsupportedRegistry);
    }

    function testChangedProxyImplementationRejected() public {
        LocalENSImplementationFixture other = new LocalENSImplementationFixture();
        factory.setImplementation(address(team), address(other));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.UnsupportedRegistry);
    }

    function testChangedConfiguredParentRegistryImplementationRejected() public {
        LocalENSImplementationFixture other = new LocalENSImplementationFixture();
        factory.setImplementation(address(community), address(other));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.UnsupportedRegistry);
    }

    function testImplementationCannotBeUsedAsChildRegistry() public {
        factory.setImplementation(address(implementation), address(implementation));
        community.setChild("team", address(implementation));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.UnsupportedRegistry);
    }

    function testSystemRootAndEthCannotBeUsedAsNestedChild() public {
        community.setChild("team", address(root));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.UnsupportedRegistry);
        community.setChild("team", address(eth));
        _reason(ALICE, _two("team", "alice"), ENSDomainGate.Reason.UnsupportedRegistry);
    }

    function testPinnedEthRouteCannotPointToAnotherVerifiedRegistry() public {
        root.setChild("eth", address(community));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.UnsupportedRegistry);
    }

    function testBackPointerDoesNotGrantOrReplaceForwardAuthority() public {
        // Forward links prove the selected alias. A registry's claimed canonical location does not.
        team.setClaimedParent(address(0xBAD), "forged");
        assertTrue(gate.isEligible(ALICE, _two("team", "alice")));
        community.setChild("team", address(0));
        assertFalse(gate.isEligible(ALICE, _two("team", "alice")));
    }

    function testRuntimeChangesFailClosed() public {
        vm.etch(address(factory), hex"00");
        assertFalse(gate.isEligible(ALICE, _one("alice")));
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.TrustChanged);
    }

    function testRootRuntimeChangeFailClosed() public {
        vm.etch(address(root), hex"00");
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.TrustChanged);
    }

    function testImplementationRuntimeChangeFailClosed() public {
        vm.etch(address(implementation), hex"00");
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.TrustChanged);
    }

    function testWrongChainFailClosed() public {
        vm.chainId(1337);
        _reason(ALICE, _one("alice"), ENSDomainGate.Reason.WrongChain);
    }

    function testZeroBeneficiaryFailClosed() public view {
        assertFalse(gate.isEligible(address(0), _one("alice")));
        _reason(address(0), _one("alice"), ENSDomainGate.Reason.InvalidBeneficiary);
    }

    function testMalformedAndNoncanonicalEvidenceFailClosed() public view {
        assertFalse(gate.isEligible(ALICE, hex"1234"));
        assertFalse(gate.isEligible(ALICE, new bytes(0)));
        bytes memory canonical = _one("alice");
        assertFalse(gate.isEligible(ALICE, bytes.concat(canonical, hex"00")));
        assertFalse(gate.isEligible(ALICE, new bytes(2049)));
    }

    function testParentItselfIsNotADescendant() public view {
        string[] memory empty = new string[](0);
        _reason(ADMIN, abi.encode(empty), ENSDomainGate.Reason.InvalidDepth);
    }

    function testLabelOrderIsNearestParentFirst() public view {
        assertTrue(gate.isEligible(ALICE, _two("team", "alice")));
        assertFalse(gate.isEligible(ALICE, _two("alice", "team")));
    }

    function testEightNestedLevelsSupportedAndNineRejected() public {
        string[] memory labels = new string[](8);
        LocalENSRegistryFixture current = community;
        for (uint256 i; i < 8; ++i) {
            labels[i] = "n";
            address child = i < 7 ? address(_newVerifiedRegistry()) : address(0);
            current.setName("n", ALICE, EXPIRY, child);
            if (i < 7) current = LocalENSRegistryFixture(child);
        }
        assertTrue(gate.isEligible(ALICE, abi.encode(labels)));
        labels = new string[](9);
        for (uint256 i; i < 9; ++i) labels[i] = "n";
        _reason(ALICE, abi.encode(labels), ENSDomainGate.Reason.InvalidDepth);
    }

    function testInvalidLabelsAreNotSilentlyNormalized() public view {
        string[11] memory invalid = [
            "", "Alice", "alice.community.eth", "-alice", "alice-", "ab--cd",
            "alice_name", " alice", "alice ", unicode"al\u00e9ce", "a\x00b"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            _reason(ALICE, _one(invalid[i]), ENSDomainGate.Reason.InvalidLabel);
        }
    }

    function testValidInternalHyphenSupported() public {
        community.setName("alice-1", ALICE, EXPIRY, address(0));
        assertTrue(gate.isEligible(ALICE, _one("alice-1")));
    }

    function testLabelLengthBoundaries() public {
        string memory valid = _repeat(63);
        community.setName(valid, ALICE, EXPIRY, address(0));
        assertTrue(gate.isEligible(ALICE, _one(valid)));
        _reason(ALICE, _one(_repeat(64)), ENSDomainGate.Reason.InvalidLabel);
    }

    function testFullDnsLengthBoundary() public {
        string[] memory labels = new string[](4);
        labels[0] = _repeat(63); labels[1] = _repeat(63); labels[2] = _repeat(63); labels[3] = _repeat(47);
        LocalENSRegistryFixture current = community;
        for (uint256 i; i < 4; ++i) {
            address child = i < 3 ? address(_newVerifiedRegistry()) : address(0);
            current.setName(labels[i], ALICE, EXPIRY, child);
            if (i < 3) current = LocalENSRegistryFixture(child);
        }
        // 15-byte parent wire name + 3 * 64 + 48 = exactly 255.
        assertTrue(gate.isEligible(ALICE, abi.encode(labels)));
        labels[3] = _repeat(48);
        _reason(ALICE, abi.encode(labels), ENSDomainGate.Reason.NameTooLong);
    }

    function testParentLabelsUseSameValidation() public {
        string[] memory parent = _parent();
        parent[1] = "Community";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
        parent[1] = "bad-";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
        parent[1] = "ab--cd";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
    }

    function testParentMustBeStrictlyBelowEth() public {
        string[] memory parent = new string[](1);
        parent[0] = "eth";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
        parent = _parent(); parent[0] = "other";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
    }

    function testParentDnsLengthAndDepthAreBounded() public {
        string[] memory parent = new string[](5);
        parent[0] = "eth";
        for (uint256 i = 1; i < 5; ++i) parent[i] = _repeat(63);
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
        parent = new string[](9); parent[0] = "eth";
        for (uint256 i = 1; i < 9; ++i) parent[i] = "n";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        new ENSDomainGate(_config(), parent);
    }

    function testConstructorRejectsInactiveOrUnlinkedParent() public {
        eth.setExpiry("community", uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGate.InvalidParentRoute.selector, ENSDomainGate.Reason.InactiveParent, uint256(1)));
        new ENSDomainGate(_config(), _parent());
        eth.setExpiry("community", EXPIRY);
        eth.setChild("community", address(0));
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGate.InvalidParentRoute.selector, ENSDomainGate.Reason.MissingSubregistry, uint256(1)));
        new ENSDomainGate(_config(), _parent());
    }

    function testLocalFixtureConfigurationCannotDeployOnSepolia() public {
        ENSDomainGate.TrustConfig memory config = _config();
        vm.chainId(11155111);
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGate.UnsupportedChain.selector, uint256(11155111)));
        new ENSDomainGate(config, _parent());
    }

    function testArbitraryTrustCannotPretendToBeRealSepolia() public {
        ENSDomainGate.TrustConfig memory config = _config();
        config.localTestOnly = false;
        vm.chainId(11155111);
        vm.expectRevert(ENSDomainGate.InvalidTrustConfiguration.selector);
        new ENSDomainGate(config, _parent());
    }

    function testUnreviewedNetworkRejected() public {
        ENSDomainGate.TrustConfig memory config = _config();
        config.localTestOnly = false;
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGate.UnsupportedChain.selector, uint256(1)));
        new ENSDomainGate(config, _parent());
    }

    function testWrongRuntimeHashRejectedAtConstruction() public {
        ENSDomainGate.TrustConfig memory config = _config();
        config.factoryCodeHash = bytes32(uint256(1));
        vm.expectRevert(ENSDomainGate.InvalidTrustConfiguration.selector);
        new ENSDomainGate(config, _parent());
    }

    function testFuzzOwnerChangesTakeEffect(address newOwner) public {
        if (newOwner == address(0)) return;
        team.transferName("alice", newOwner);
        assertTrue(gate.isEligible(newOwner, _two("team", "alice")));
        if (newOwner != ALICE) assertFalse(gate.isEligible(ALICE, _two("team", "alice")));
    }

    function _reason(address beneficiary, bytes memory evidence, ENSDomainGate.Reason expected) internal view {
        ENSDomainGate.Eligibility memory result = gate.inspect(beneficiary, evidence);
        assertFalse(result.eligible);
        assertEq(uint256(result.reason), uint256(expected));
        assertFalse(gate.isEligible(beneficiary, evidence));
    }

    function _newVerifiedRegistry() internal returns (LocalENSRegistryFixture value) {
        value = new LocalENSRegistryFixture();
        factory.setImplementation(address(value), address(implementation));
    }

    function _config() internal view returns (ENSDomainGate.TrustConfig memory) {
        return ENSDomainGate.TrustConfig(
            address(root), address(eth), address(factory), address(implementation),
            address(root).codehash, address(eth).codehash, address(factory).codehash,
            address(implementation).codehash, true
        );
    }

    function _parent() internal pure returns (string[] memory labels) {
        labels = new string[](2); labels[0] = "eth"; labels[1] = "community";
    }

    function _one(string memory label) internal pure returns (bytes memory) {
        string[] memory labels = new string[](1); labels[0] = label; return abi.encode(labels);
    }

    function _two(string memory first, string memory second) internal pure returns (bytes memory) {
        string[] memory labels = new string[](2); labels[0] = first; labels[1] = second; return abi.encode(labels);
    }

    function _repeat(uint256 length) internal pure returns (string memory) {
        bytes memory value = new bytes(length);
        for (uint256 i; i < length; ++i) value[i] = "a";
        return string(value);
    }
}
