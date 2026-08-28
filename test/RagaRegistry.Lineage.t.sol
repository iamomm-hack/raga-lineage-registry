// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    Attestation,
    EMPTY_UID
} from "@ethereum-attestation-service/eas-contracts/contracts/Common.sol";
import { EAS } from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import { IEAS } from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {
    ISchemaResolver
} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";
import {
    SchemaRegistry
} from "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";

import { RagaRegistry } from "../src/RagaRegistry.sol";

contract RagaRegistryLineageTest is Test {
    string internal constant LINEAGE_SCHEMA =
        "address student,address teacher,uint16 teacherShareBps";
    string internal constant LICENSE_SCHEMA =
        "bytes32 assetId,address performer,address licensee,bytes32 lineageUID";
    uint16 internal constant TEACHER_SHARE_BPS = 2_000;

    address internal student = makeAddr("student");
    address internal teacherA = makeAddr("teacherA");
    address internal teacherB = makeAddr("teacherB");
    address internal randomUser = makeAddr("randomUser");

    SchemaRegistry internal schemaRegistry;
    EAS internal eas;
    RagaRegistry internal ragaRegistry;
    bytes32 internal lineageSchemaUID;
    bytes32 internal licenseSchemaUID;

    function setUp() public {
        vm.warp(1_000_000);

        schemaRegistry = new SchemaRegistry();
        eas = new EAS(schemaRegistry);
        lineageSchemaUID =
            schemaRegistry.register(LINEAGE_SCHEMA, ISchemaResolver(address(0)), true);
        licenseSchemaUID =
            schemaRegistry.register(LICENSE_SCHEMA, ISchemaResolver(address(0)), true);
        ragaRegistry = new RagaRegistry(IEAS(address(eas)), lineageSchemaUID, licenseSchemaUID);
    }

    function testRoleGatingRejectsUnauthorizedThenAllowsGrantedStudent() public {
        bytes32 lineageRole = ragaRegistry.LINEAGE_ATTESTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, student, lineageRole
            )
        );
        vm.prank(student);
        ragaRegistry.proposeTeacher(teacherA, TEACHER_SHARE_BPS);

        _grantStudentRole();
        vm.prank(student);
        ragaRegistry.proposeTeacher(teacherA, TEACHER_SHARE_BPS);

        (address proposedTeacher, uint16 shareBps, bool exists) =
            ragaRegistry.getPendingProposal(student);
        assertTrue(exists);
        assertEq(proposedTeacher, teacherA);
        assertEq(shareBps, TEACHER_SHARE_BPS);
    }

    function testProposalIsPendingAndNotVerifiedLineage() public {
        _proposeTeacherA();

        assertEq(
            uint256(ragaRegistry.lineageState(student)), uint256(RagaRegistry.LineageState.Pending)
        );
        assertFalse(ragaRegistry.hasValidLineage(student));
    }

    function testWrongTeacherCannotAccept() public {
        _proposeTeacherA();

        vm.prank(teacherB);
        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.NotProposedTeacher.selector, teacherB, teacherA)
        );
        ragaRegistry.acceptStudent(student);
    }

    function testExactTeacherAcceptanceCreatesGenuineEASRecord() public {
        _proposeTeacherA();

        vm.prank(teacherA);
        bytes32 uid = ragaRegistry.acceptStudent(student);

        assertNotEq(uid, EMPTY_UID);
        Attestation memory attestation = eas.getAttestation(uid);
        assertEq(attestation.uid, uid);
        assertEq(attestation.schema, lineageSchemaUID);
        assertEq(attestation.attester, address(ragaRegistry));
        assertEq(attestation.recipient, student);
        assertTrue(attestation.revocable);
        assertEq(attestation.revocationTime, 0);

        (address encodedStudent, address encodedTeacher, uint16 encodedShareBps) =
            abi.decode(attestation.data, (address, address, uint16));
        assertEq(encodedStudent, student);
        assertEq(encodedTeacher, teacherA);
        assertEq(encodedShareBps, TEACHER_SHARE_BPS);

        (
            bytes32 indexedUID,
            address indexedTeacher,
            uint16 indexedShareBps,
            RagaRegistry.LineageState state
        ) = ragaRegistry.getLineage(student);
        assertEq(indexedUID, uid);
        assertEq(indexedTeacher, teacherA);
        assertEq(indexedShareBps, TEACHER_SHARE_BPS);
        assertEq(uint256(state), uint256(RagaRegistry.LineageState.Active));
        assertTrue(ragaRegistry.hasValidLineage(student));
    }

    function testSelfTeacherIsRejected() public {
        _grantStudentRole();

        vm.prank(student);
        vm.expectRevert(RagaRegistry.SelfTeaching.selector);
        ragaRegistry.proposeTeacher(student, TEACHER_SHARE_BPS);
    }

    function testTeacherShareAboveMaximumIsRejected() public {
        _grantStudentRole();

        vm.prank(student);
        vm.expectRevert(abi.encodeWithSelector(RagaRegistry.InvalidTeacherShare.selector, 10_001));
        ragaRegistry.proposeTeacher(teacherA, 10_001);
    }

    function testDuplicateUnresolvedProposalIsRejected() public {
        _proposeTeacherA();

        vm.prank(student);
        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.PendingProposalExists.selector, student)
        );
        ragaRegistry.proposeTeacher(teacherB, 1_000);
    }

    function testTeacherRevocationChangesLiveEASState() public {
        bytes32 uid = _acceptTeacherA();
        assertEq(
            uint256(ragaRegistry.lineageState(student)), uint256(RagaRegistry.LineageState.Active)
        );

        vm.prank(teacherA);
        ragaRegistry.revokeLineage(student);

        Attestation memory attestation = eas.getAttestation(uid);
        assertGt(attestation.revocationTime, 0);
        assertEq(
            uint256(ragaRegistry.lineageState(student)), uint256(RagaRegistry.LineageState.Revoked)
        );
        assertFalse(ragaRegistry.hasValidLineage(student));
    }

    function testNonTeacherCannotRevoke() public {
        _acceptTeacherA();

        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.NotLineageTeacher.selector, randomUser, teacherA)
        );
        ragaRegistry.revokeLineage(student);
    }

    function testStudentRoleIsRecheckedAtAcceptance() public {
        _proposeTeacherA();
        bytes32 lineageRole = ragaRegistry.LINEAGE_ATTESTER_ROLE();
        ragaRegistry.revokeRole(lineageRole, student);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, student, lineageRole
            )
        );
        vm.prank(teacherA);
        ragaRegistry.acceptStudent(student);
    }

    function testZeroTeacherIsRejected() public {
        _grantStudentRole();

        vm.prank(student);
        vm.expectRevert(RagaRegistry.ZeroTeacher.selector);
        ragaRegistry.proposeTeacher(address(0), TEACHER_SHARE_BPS);
    }

    function testActiveLineagePreventsAnotherProposal() public {
        _acceptTeacherA();

        vm.prank(student);
        vm.expectRevert(abi.encodeWithSelector(RagaRegistry.ActiveLineageExists.selector, student));
        ragaRegistry.proposeTeacher(teacherB, 1_000);
    }

    function testTeacherAcceptanceRejectsTwoNodeCycle() public {
        _acceptTeacherA();

        ragaRegistry.grantRole(ragaRegistry.LINEAGE_ATTESTER_ROLE(), teacherA);
        vm.prank(teacherA);
        ragaRegistry.proposeTeacher(student, TEACHER_SHARE_BPS);

        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.LineageCycle.selector, teacherA, student)
        );
        vm.prank(student);
        ragaRegistry.acceptStudent(teacherA);

        assertEq(
            uint256(ragaRegistry.lineageState(teacherA)), uint256(RagaRegistry.LineageState.Pending)
        );
        assertFalse(ragaRegistry.hasValidLineage(teacherA));
    }

    function _grantStudentRole() internal {
        ragaRegistry.grantRole(ragaRegistry.LINEAGE_ATTESTER_ROLE(), student);
    }

    function _proposeTeacherA() internal {
        _grantStudentRole();
        vm.prank(student);
        ragaRegistry.proposeTeacher(teacherA, TEACHER_SHARE_BPS);
    }

    function _acceptTeacherA() internal returns (bytes32 uid) {
        _proposeTeacherA();
        vm.prank(teacherA);
        uid = ragaRegistry.acceptStudent(student);
    }
}
