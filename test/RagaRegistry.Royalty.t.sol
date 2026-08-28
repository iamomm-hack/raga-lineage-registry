// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    ISchemaResolver
} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";
import { EAS } from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import { IEAS } from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {
    SchemaRegistry
} from "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";

import { RagaRegistry } from "../src/RagaRegistry.sol";

contract RagaRegistryRoyaltyTest is Test {
    string internal constant LINEAGE_SCHEMA =
        "address student,address teacher,uint16 teacherShareBps";
    string internal constant LICENSE_SCHEMA =
        "bytes32 assetId,address performer,address licensee,bytes32 lineageUID";
    uint64 internal constant START_TIME = 1_000_000;
    uint64 internal constant LICENSE_DURATION = 30 days;
    bytes32 internal constant ASSET_ID = keccak256("royalty-raga-recording");

    address internal performer = makeAddr("performer");
    address internal guruA = makeAddr("guruA");
    address internal guruB = makeAddr("guruB");
    address internal guruC = makeAddr("guruC");
    address internal issuer = makeAddr("issuer");
    address internal licensee = makeAddr("licensee");

    EAS internal eas;
    RagaRegistry internal ragaRegistry;

    function setUp() public {
        vm.warp(START_TIME);

        SchemaRegistry schemaRegistry = new SchemaRegistry();
        eas = new EAS(schemaRegistry);
        bytes32 lineageSchemaUID =
            schemaRegistry.register(LINEAGE_SCHEMA, ISchemaResolver(address(0)), true);
        bytes32 licenseSchemaUID =
            schemaRegistry.register(LICENSE_SCHEMA, ISchemaResolver(address(0)), true);
        ragaRegistry = new RagaRegistry(IEAS(address(eas)), lineageSchemaUID, licenseSchemaUID);
    }

    function testNoLineagePaysPerformerFully() public view {
        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 10_000);

        assertEq(allocations.length, 1);
        _assertAllocation(allocations[0], performer, 10_000);
    }

    function testOneHopLineageUsesRecordedShare() public {
        _createLineage(performer, guruA, 2_000);

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 10_000);

        assertEq(allocations.length, 2);
        _assertAllocation(allocations[0], performer, 8_000);
        _assertAllocation(allocations[1], guruA, 2_000);
    }

    function testMultiHopLineageCascadesRecordedShares() public {
        _createLineage(performer, guruA, 2_000);
        _createLineage(guruA, guruB, 2_500);

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 10_000);

        assertEq(allocations.length, 3);
        _assertAllocation(allocations[0], performer, 8_000);
        _assertAllocation(allocations[1], guruA, 1_500);
        _assertAllocation(allocations[2], guruB, 500);
    }

    function testResultsConserveGrossAcrossSeveralSharesAndAmounts() public {
        _createLineage(performer, guruA, 1_234);
        _createLineage(guruA, guruB, 5_678);
        _createLineage(guruB, guruC, 9_999);
        uint256[4] memory grossAmounts = [uint256(1), 101, 10_000, type(uint128).max];

        for (uint256 i = 0; i < grossAmounts.length; ++i) {
            RagaRegistry.RoyaltyAllocation[] memory allocations =
                ragaRegistry.resolveRoyalties(performer, grossAmounts[i]);
            assertEq(_sum(allocations), grossAmounts[i]);
        }
    }

    function testRoundingDustRemainsWithCurrentStudent() public {
        _createLineage(performer, guruA, 3_333);

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 101);

        assertEq(allocations.length, 2);
        _assertAllocation(allocations[0], performer, 68);
        _assertAllocation(allocations[1], guruA, 33);
        assertEq(_sum(allocations), 101);
    }

    function testZeroShareStopsWithoutZeroTeacherAllocation() public {
        _createLineage(performer, guruA, 0);

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 10_000);

        assertEq(allocations.length, 1);
        _assertAllocation(allocations[0], performer, 10_000);
    }

    function testFullShareOmitsZeroPerformerAllocation() public {
        _createLineage(performer, guruA, 10_000);

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 10_000);

        assertEq(allocations.length, 1);
        _assertAllocation(allocations[0], guruA, 10_000);
    }

    function testRevokedEdgeChangesCurrentRoyaltyResolution() public {
        _createLineage(performer, guruA, 2_000);
        RagaRegistry.RoyaltyAllocation[] memory beforeRevocation =
            ragaRegistry.resolveRoyalties(performer, 10_000);
        assertEq(beforeRevocation.length, 2);
        _assertAllocation(beforeRevocation[0], performer, 8_000);
        _assertAllocation(beforeRevocation[1], guruA, 2_000);

        vm.prank(guruA);
        ragaRegistry.revokeLineage(performer);

        RagaRegistry.RoyaltyAllocation[] memory afterRevocation =
            ragaRegistry.resolveRoyalties(performer, 10_000);
        assertEq(afterRevocation.length, 1);
        _assertAllocation(afterRevocation[0], performer, 10_000);
    }

    function testReplacementLineageChangesStandaloneResolution() public {
        _createLineage(performer, guruA, 2_000);
        vm.prank(guruA);
        ragaRegistry.revokeLineage(performer);
        _createLineage(performer, guruB, 4_000);

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 10_000);

        assertEq(allocations.length, 2);
        _assertAllocation(allocations[0], performer, 6_000);
        _assertAllocation(allocations[1], guruB, 4_000);
    }

    function testOldLicenseCannotUseReplacementLineage() public {
        _createLineage(performer, guruA, 2_000);
        _issueLicense();

        vm.prank(guruA);
        ragaRegistry.revokeLineage(performer);
        _createLineage(performer, guruB, 4_000);

        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.InvalidLineage)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                RagaRegistry.LicenseNotActiveForRoyalties.selector,
                RagaRegistry.LicenseState.InvalidLineage
            )
        );
        ragaRegistry.resolveLicensedRoyalties(ASSET_ID, licensee, 10_000);
    }

    function testActiveLicensedRoyaltiesUseMultiHopGraph() public {
        _createLineage(performer, guruA, 2_000);
        _createLineage(guruA, guruB, 2_500);
        _issueLicense();

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveLicensedRoyalties(ASSET_ID, licensee, 10_000);

        assertEq(allocations.length, 3);
        _assertAllocation(allocations[0], performer, 8_000);
        _assertAllocation(allocations[1], guruA, 1_500);
        _assertAllocation(allocations[2], guruB, 500);
    }

    function testExpiredLicenseCannotResolveLicensedRoyalties() public {
        _createLineage(performer, guruA, 2_000);
        _issueLicense();
        vm.warp(START_TIME + LICENSE_DURATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                RagaRegistry.LicenseNotActiveForRoyalties.selector,
                RagaRegistry.LicenseState.Expired
            )
        );
        ragaRegistry.resolveLicensedRoyalties(ASSET_ID, licensee, 10_000);
    }

    function testRevokedLicenseCannotResolveLicensedRoyalties() public {
        _createLineage(performer, guruA, 2_000);
        _issueLicense();
        vm.prank(issuer);
        ragaRegistry.revokeLicense(ASSET_ID, licensee);

        vm.expectRevert(
            abi.encodeWithSelector(
                RagaRegistry.LicenseNotActiveForRoyalties.selector,
                RagaRegistry.LicenseState.Revoked
            )
        );
        ragaRegistry.resolveLicensedRoyalties(ASSET_ID, licensee, 10_000);
    }

    function testUnlicensedPairCannotResolveLicensedRoyalties() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                RagaRegistry.LicenseNotActiveForRoyalties.selector,
                RagaRegistry.LicenseState.Unlicensed
            )
        );
        ragaRegistry.resolveLicensedRoyalties(ASSET_ID, licensee, 10_000);
    }

    function testMaxDepthResolvesTerminalButRejectsAdditionalActiveEdge() public {
        uint256 maxDepth = ragaRegistry.MAX_LINEAGE_DEPTH();
        address[] memory nodes = new address[](maxDepth + 2);
        for (uint256 i = 0; i < nodes.length; ++i) {
            nodes[i] = address(uint160(0x1000 + i));
        }
        for (uint256 i = 0; i < maxDepth; ++i) {
            _createLineage(nodes[i], nodes[i + 1], 10_000);
        }

        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(nodes[0], 10_000);
        assertEq(allocations.length, 1);
        _assertAllocation(allocations[0], nodes[maxDepth], 10_000);

        _createLineage(nodes[maxDepth], nodes[maxDepth + 1], 10_000);
        vm.expectRevert(RagaRegistry.LineageDepthExceeded.selector);
        ragaRegistry.resolveRoyalties(nodes[0], 10_000);
    }

    function testZeroPerformerIsRejected() public {
        vm.expectRevert(RagaRegistry.ZeroPerformer.selector);
        ragaRegistry.resolveRoyalties(address(0), 10_000);
    }

    function testZeroGrossReturnsEmptyAllocations() public view {
        RagaRegistry.RoyaltyAllocation[] memory allocations =
            ragaRegistry.resolveRoyalties(performer, 0);
        assertEq(allocations.length, 0);
    }

    function _createLineage(address student, address teacher, uint16 shareBps)
        internal
        returns (bytes32 uid)
    {
        if (!ragaRegistry.hasRole(ragaRegistry.LINEAGE_ATTESTER_ROLE(), student)) {
            ragaRegistry.grantRole(ragaRegistry.LINEAGE_ATTESTER_ROLE(), student);
        }
        vm.prank(student);
        ragaRegistry.proposeTeacher(teacher, shareBps);
        vm.prank(teacher);
        uid = ragaRegistry.acceptStudent(student);
    }

    function _issueLicense() internal returns (bytes32 uid) {
        if (!ragaRegistry.hasRole(ragaRegistry.LICENSOR_ROLE(), issuer)) {
            ragaRegistry.grantRole(ragaRegistry.LICENSOR_ROLE(), issuer);
        }
        vm.prank(issuer);
        uid = ragaRegistry.issueLicense(
            ASSET_ID, performer, licensee, START_TIME + LICENSE_DURATION
        );
    }

    function _assertAllocation(
        RagaRegistry.RoyaltyAllocation memory allocation,
        address expectedRecipient,
        uint256 expectedAmount
    ) internal pure {
        assertEq(allocation.recipient, expectedRecipient);
        assertEq(allocation.amount, expectedAmount);
    }

    function _sum(RagaRegistry.RoyaltyAllocation[] memory allocations)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < allocations.length; ++i) {
            total += allocations[i].amount;
        }
    }
}
