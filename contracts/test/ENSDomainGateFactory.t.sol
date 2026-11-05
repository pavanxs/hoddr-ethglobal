// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ENSDomainGate} from "../src/ENSDomainGate.sol";
import {ENSDomainGateFactory} from "../src/ENSDomainGateFactory.sol";
import {IdentityENSTestBase} from "./helpers/IdentityENSTestBase.sol";
import {
    LocalENSRegistryFixture, LocalENSFactoryFixture, LocalENSImplementationFixture
} from "./mocks/LocalENSFixtures.sol";

contract ENSDomainGateFactoryTest is IdentityENSTestBase {
    address internal constant ALICE = address(0xA11CE);
    LocalENSRegistryFixture internal root;
    LocalENSRegistryFixture internal eth;
    LocalENSRegistryFixture internal community;
    LocalENSFactoryFixture internal registryFactory;
    LocalENSImplementationFixture internal implementation;
    ENSDomainGateFactory internal gateFactory;
    bytes32 internal constant PARENT_NODE = 0x220302cfbfda77f912157d62bd2a0d4553d6d73e677960d357c09235621436f8;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1000);
        root = new LocalENSRegistryFixture();
        eth = new LocalENSRegistryFixture();
        community = new LocalENSRegistryFixture();
        registryFactory = new LocalENSFactoryFixture();
        implementation = new LocalENSImplementationFixture();
        registryFactory.setImplementation(address(community), address(implementation));
        root.setName("eth", ALICE, type(uint64).max, address(eth));
        eth.setName("community", ALICE, 2000, address(community));
        community.setName("alice", ALICE, 2000, address(0));
        gateFactory = new ENSDomainGateFactory(_config());
    }

    function testCreateRegistersOnlyActualGateWithFixedPolicy() public {
        address created = gateFactory.create(_parent());
        assertTrue(gateFactory.isGate(created));
        assertEq(gateFactory.gateForParent(PARENT_NODE), created);
        ENSDomainGate gate = ENSDomainGate(created);
        assertEq(gate.rootRegistry(), address(root));
        assertEq(gate.parentNamehash(), PARENT_NODE);
        assertEq(gate.parentDomain(), "community.eth");
        assertTrue(gate.localTestOnly());
        assertTrue(gate.isEligible(ALICE, _evidence()));
    }

    function testDirectOrLookalikeAddressIsNotRecognized() public {
        ENSDomainGate direct = new ENSDomainGate(_config(), _parent());
        assertFalse(gateFactory.isGate(address(direct)));
        assertFalse(gateFactory.isGate(address(community)));
        assertFalse(gateFactory.isGate(address(0)));
        assertEq(gateFactory.gateForParent(PARENT_NODE), address(0));
    }

    function testDuplicateParentReusesGateAcrossCallers() public {
        address first = gateFactory.create(_parent());
        vm.prank(address(0xB0B));
        address second = gateFactory.create(_parent());
        assertEq(first, second);
        assertTrue(gateFactory.isGate(second));
    }

    function testReuseRechecksParentExpiry() public {
        address created = gateFactory.create(_parent());
        eth.setExpiry("community", uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGateFactory.ParentUnavailable.selector, ENSDomainGate.Reason.InactiveParent, uint256(1)));
        gateFactory.create(_parent());
        // Provenance history remains true, while present eligibility is false.
        assertTrue(gateFactory.isGate(created));
        assertFalse(ENSDomainGate(created).isEligible(ALICE, _evidence()));
    }

    function testReuseRechecksRegistryImplementation() public {
        gateFactory.create(_parent());
        LocalENSImplementationFixture other = new LocalENSImplementationFixture();
        registryFactory.setImplementation(address(community), address(other));
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGateFactory.ParentUnavailable.selector, ENSDomainGate.Reason.UnsupportedRegistry, uint256(1)));
        gateFactory.create(_parent());
    }

    function testInvalidParentNeverRegistersGate() public {
        string[] memory parent = _parent();
        parent[1] = "Community";
        vm.expectRevert(ENSDomainGate.UnsupportedParent.selector);
        gateFactory.create(parent);
        assertEq(gateFactory.gateForParent(PARENT_NODE), address(0));
    }

    function testMissingParentNeverRegistersGate() public {
        string[] memory parent = _parent();
        parent[1] = "absent";
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGate.InvalidParentRoute.selector, ENSDomainGate.Reason.InactiveParent, uint256(1)));
        gateFactory.create(parent);
        assertEq(gateFactory.gateForParent(PARENT_NODE), address(0));
    }

    function testDifferentValidParentGetsDifferentGate() public {
        address first = gateFactory.create(_parent());
        LocalENSRegistryFixture other = new LocalENSRegistryFixture();
        registryFactory.setImplementation(address(other), address(implementation));
        eth.setName("another", ALICE, 2000, address(other));
        string[] memory parent = _parent(); parent[1] = "another";
        address second = gateFactory.create(parent);
        assertTrue(second != first);
        assertTrue(gateFactory.isGate(first));
        assertTrue(gateFactory.isGate(second));
        assertEq(ENSDomainGate(second).parentDomain(), "another.eth");
    }

    function testWrongChainBlocksCreationAndReuse() public {
        gateFactory.create(_parent());
        vm.chainId(1337);
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGateFactory.WrongChain.selector, uint256(31337), uint256(1337)));
        gateFactory.create(_parent());
    }

    function testTrustConfigIsReadOnlyAndCopied() public view {
        ENSDomainGate.TrustConfig memory value = gateFactory.trustConfig();
        assertEq(value.rootRegistry, address(root));
        value.rootRegistry = address(0xBAD);
        assertEq(gateFactory.trustConfig().rootRegistry, address(root));
    }

    function testLocalFactoryCannotDeployOnSepolia() public {
        ENSDomainGate.TrustConfig memory config = _config();
        vm.chainId(11155111);
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGateFactory.UnsupportedChain.selector, uint256(11155111)));
        new ENSDomainGateFactory(config);
    }

    function testRealFactoryRejectsFakeSepoliaTrust() public {
        ENSDomainGate.TrustConfig memory config = _config();
        config.localTestOnly = false;
        vm.chainId(11155111);
        vm.expectRevert(ENSDomainGateFactory.InvalidTrustConfiguration.selector);
        new ENSDomainGateFactory(config);
    }

    function testFactoryRejectsUnreviewedChain() public {
        ENSDomainGate.TrustConfig memory config = _config(); config.localTestOnly = false;
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ENSDomainGateFactory.UnsupportedChain.selector, uint256(1)));
        new ENSDomainGateFactory(config);
    }

    function testFactoryRejectsWrongCodeHash() public {
        ENSDomainGate.TrustConfig memory config = _config(); config.rootCodeHash = bytes32(uint256(1));
        vm.expectRevert(ENSDomainGateFactory.InvalidTrustConfiguration.selector);
        new ENSDomainGateFactory(config);
    }

    function testFactoryBoundsParentDepthBeforeDeployment() public {
        string[] memory parent = new string[](9);
        for (uint256 i; i < parent.length; ++i) parent[i] = "n";
        vm.expectRevert(ENSDomainGateFactory.UnsupportedParent.selector);
        gateFactory.create(parent);
    }

    function _config() internal view returns (ENSDomainGate.TrustConfig memory) {
        return ENSDomainGate.TrustConfig(
            address(root), address(eth), address(registryFactory), address(implementation),
            address(root).codehash, address(eth).codehash, address(registryFactory).codehash,
            address(implementation).codehash, true
        );
    }

    function _parent() internal pure returns (string[] memory parent) {
        parent = new string[](2); parent[0] = "eth"; parent[1] = "community";
    }

    function _evidence() internal pure returns (bytes memory) {
        string[] memory labels = new string[](1); labels[0] = "alice"; return abi.encode(labels);
    }
}
