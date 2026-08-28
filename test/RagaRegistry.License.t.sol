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

contract RagaRegistryLicenseTest is Test {
    string internal constant LINEAGE_SCHEMA =
        "address student,address teacher,uint16 teacherShareBps";
    string internal constant LICENSE_SCHEMA =
        "bytes32 assetId,address performer,address licensee,bytes32 lineageUID";
    uint16 internal constant TEACHER_SHARE_BPS = 2_000;
    uint64 internal constant START_TIME = 1_000_000;
    uint64 internal constant LICENSE_DURATION = 30 days;
    bytes32 internal constant ASSET_ID = keccak256("raga-recording-1");

    address internal performer = makeAddr("performer");
    address internal teacherA = makeAddr("teacherA");
    address internal teacherB = makeAddr("teacherB");
    address internal issuer = makeAddr("issuer");
    address internal licensee = makeAddr("licensee");
    address internal randomUser = makeAddr("randomUser");

    SchemaRegistry internal schemaRegistry;
    EAS internal eas;
    RagaRegistry internal ragaRegistry;
    bytes32 internal lineageSchemaUID;
    bytes32 internal licenseSchemaUID;

    function setUp() public {
        vm.warp(START_TIME);

        schemaRegistry = new SchemaRegistry();
        eas = new EAS(schemaRegistry);
        lineageSchemaUID =
            schemaRegistry.register(LINEAGE_SCHEMA, ISchemaResolver(address(0)), true);
        licenseSchemaUID =
            schemaRegistry.register(LICENSE_SCHEMA, ISchemaResolver(address(0)), true);
        ragaRegistry = new RagaRegistry(IEAS(address(eas)), lineageSchemaUID, licenseSchemaUID);
    }

    function testUnlicensedStateIsDistinct() public view {
        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.Unlicensed)
        );
        assertFalse(ragaRegistry.isLicenseValid(ASSET_ID, licensee));
    }

    function testUnauthorizedIssuerIsRejected() public {
        _createLineage(teacherA);
        bytes32 licensorRole = ragaRegistry.LICENSOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, licensorRole
            )
        );
        vm.prank(randomUser);
        ragaRegistry.issueLicense(ASSET_ID, performer, licensee, START_TIME + LICENSE_DURATION);
    }

    function testCannotLicenseWithoutValidLineage() public {
        _grantLicensorRole();

        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.PerformerLineageNotActive.selector, performer)
        );
        vm.prank(issuer);
        ragaRegistry.issueLicense(ASSET_ID, performer, licensee, START_TIME + LICENSE_DURATION);
    }

    function testIssueCreatesGenuineEASLicense() public {
        bytes32 lineageUID = _createLineage(teacherA);
        uint64 expirationTime = START_TIME + LICENSE_DURATION;
        bytes32 licenseUID = _issueLicense(expirationTime);

        assertNotEq(licenseUID, EMPTY_UID);
        Attestation memory attestation = eas.getAttestation(licenseUID);
        assertEq(attestation.uid, licenseUID);
        assertEq(attestation.schema, licenseSchemaUID);
        assertEq(attestation.attester, address(ragaRegistry));
        assertEq(attestation.recipient, licensee);
        assertEq(attestation.expirationTime, expirationTime);
        assertTrue(attestation.revocable);
        assertEq(attestation.revocationTime, 0);

        (
            bytes32 encodedAssetId,
            address encodedPerformer,
            address encodedLicensee,
            bytes32 encodedLineageUID
        ) = abi.decode(attestation.data, (bytes32, address, address, bytes32));
        assertEq(encodedAssetId, ASSET_ID);
        assertEq(encodedPerformer, performer);
        assertEq(encodedLicensee, licensee);
        assertEq(encodedLineageUID, lineageUID);

        (
            bytes32 indexedUID,
            address indexedPerformer,
            bytes32 indexedLineageUID,
            uint64 indexedExpirationTime,
            RagaRegistry.LicenseState state
        ) = ragaRegistry.getLicense(ASSET_ID, licensee);
        assertEq(indexedUID, licenseUID);
        assertEq(indexedPerformer, performer);
        assertEq(indexedLineageUID, lineageUID);
        assertEq(indexedExpirationTime, expirationTime);
        assertEq(uint256(state), uint256(RagaRegistry.LicenseState.Active));
        assertTrue(ragaRegistry.isLicenseValid(ASSET_ID, licensee));
    }

    function testExpiryIsCheckedAtTimeOfUse() public {
        _createLineage(teacherA);
        uint64 expirationTime = START_TIME + LICENSE_DURATION;
        bytes32 licenseUID = _issueLicense(expirationTime);

        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.Active)
        );
        vm.warp(expirationTime);

        Attestation memory attestation = eas.getAttestation(licenseUID);
        assertEq(attestation.uid, licenseUID);
        assertEq(attestation.expirationTime, expirationTime);
        assertEq(attestation.revocationTime, 0);
        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.Expired)
        );
        assertFalse(ragaRegistry.isLicenseValid(ASSET_ID, licensee));
    }

    function testExpiredDiffersFromNeverLicensed() public {
        _createLineage(teacherA);
        uint64 expirationTime = START_TIME + LICENSE_DURATION;
        _issueLicense(expirationTime);
        vm.warp(expirationTime);

        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.Expired)
        );
        assertEq(
            uint256(ragaRegistry.licenseState(keccak256("unknown"), randomUser)),
            uint256(RagaRegistry.LicenseState.Unlicensed)
        );
    }

    function testOriginalIssuerRevocationChangesLiveEASState() public {
        _createLineage(teacherA);
        bytes32 licenseUID = _issueLicense(START_TIME + LICENSE_DURATION);

        vm.prank(issuer);
        ragaRegistry.revokeLicense(ASSET_ID, licensee);

        Attestation memory attestation = eas.getAttestation(licenseUID);
        assertGt(attestation.revocationTime, 0);
        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.Revoked)
        );
        assertFalse(ragaRegistry.isLicenseValid(ASSET_ID, licensee));
    }

    function testNonIssuerCannotRevoke() public {
        _createLineage(teacherA);
        _issueLicense(START_TIME + LICENSE_DURATION);

        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.NotLicenseIssuer.selector, randomUser, issuer)
        );
        vm.prank(randomUser);
        ragaRegistry.revokeLicense(ASSET_ID, licensee);
    }

    function testTeacherLineageRevocationInvalidatesUnrevokedLicense() public {
        _createLineage(teacherA);
        bytes32 licenseUID = _issueLicense(START_TIME + LICENSE_DURATION);

        vm.prank(teacherA);
        ragaRegistry.revokeLineage(performer);

        Attestation memory licenseAttestation = eas.getAttestation(licenseUID);
        assertEq(licenseAttestation.revocationTime, 0);
        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.InvalidLineage)
        );
        assertFalse(ragaRegistry.isLicenseValid(ASSET_ID, licensee));
    }

    function testLicenseRemainsBoundToCapturedLineageUID() public {
        bytes32 lineageUIDA = _createLineage(teacherA);
        bytes32 oldLicenseUID = _issueLicense(START_TIME + LICENSE_DURATION);

        vm.prank(teacherA);
        ragaRegistry.revokeLineage(performer);
        bytes32 lineageUIDB = _createLineage(teacherB);

        assertNotEq(lineageUIDA, lineageUIDB);
        assertEq(
            uint256(ragaRegistry.licenseState(ASSET_ID, licensee)),
            uint256(RagaRegistry.LicenseState.InvalidLineage)
        );

        Attestation memory oldLicense = eas.getAttestation(oldLicenseUID);
        (,,, bytes32 capturedLineageUID) =
            abi.decode(oldLicense.data, (bytes32, address, address, bytes32));
        assertEq(capturedLineageUID, lineageUIDA);
        assertEq(oldLicense.revocationTime, 0);

        bytes32 newLicenseUID = _issueLicense(START_TIME + (2 * LICENSE_DURATION));
        assertNotEq(newLicenseUID, oldLicenseUID);
        (,, bytes32 newCapturedLineageUID,, RagaRegistry.LicenseState newState) =
            ragaRegistry.getLicense(ASSET_ID, licensee);
        assertEq(newCapturedLineageUID, lineageUIDB);
        assertEq(uint256(newState), uint256(RagaRegistry.LicenseState.Active));
    }

    function testDuplicateActiveLicenseIsRejected() public {
        _createLineage(teacherA);
        uint64 expirationTime = START_TIME + LICENSE_DURATION;
        _issueLicense(expirationTime);

        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.ActiveLicenseExists.selector, ASSET_ID, licensee)
        );
        vm.prank(issuer);
        ragaRegistry.issueLicense(ASSET_ID, performer, licensee, expirationTime + 1 days);
    }

    function testReissueAfterExpiryUpdatesOnlyDiscoveryIndex() public {
        _createLineage(teacherA);
        uint64 oldExpirationTime = START_TIME + LICENSE_DURATION;
        bytes32 oldUID = _issueLicense(oldExpirationTime);
        vm.warp(oldExpirationTime);

        bytes32 newUID = _issueLicense(oldExpirationTime + LICENSE_DURATION);

        assertNotEq(newUID, oldUID);
        (bytes32 indexedUID,,,, RagaRegistry.LicenseState state) =
            ragaRegistry.getLicense(ASSET_ID, licensee);
        assertEq(indexedUID, newUID);
        assertEq(uint256(state), uint256(RagaRegistry.LicenseState.Active));

        Attestation memory historicalAttestation = eas.getAttestation(oldUID);
        assertEq(historicalAttestation.uid, oldUID);
        assertEq(historicalAttestation.expirationTime, oldExpirationTime);
        assertEq(historicalAttestation.revocationTime, 0);
    }

    function testZeroAssetIdIsRejected() public {
        _createLineage(teacherA);
        _grantLicensorRole();

        vm.expectRevert(RagaRegistry.ZeroAssetId.selector);
        vm.prank(issuer);
        ragaRegistry.issueLicense(EMPTY_UID, performer, licensee, START_TIME + LICENSE_DURATION);
    }

    function testZeroPerformerIsRejected() public {
        _grantLicensorRole();

        vm.expectRevert(RagaRegistry.ZeroPerformer.selector);
        vm.prank(issuer);
        ragaRegistry.issueLicense(ASSET_ID, address(0), licensee, START_TIME + LICENSE_DURATION);
    }

    function testZeroLicenseeIsRejected() public {
        _createLineage(teacherA);
        _grantLicensorRole();

        vm.expectRevert(RagaRegistry.ZeroLicensee.selector);
        vm.prank(issuer);
        ragaRegistry.issueLicense(ASSET_ID, performer, address(0), START_TIME + LICENSE_DURATION);
    }

    function testNonFutureExpirationIsRejected() public {
        _createLineage(teacherA);
        _grantLicensorRole();

        vm.expectRevert(
            abi.encodeWithSelector(RagaRegistry.InvalidLicenseExpiration.selector, START_TIME)
        );
        vm.prank(issuer);
        ragaRegistry.issueLicense(ASSET_ID, performer, licensee, START_TIME);
    }

    function _grantLicensorRole() internal {
        if (!ragaRegistry.hasRole(ragaRegistry.LICENSOR_ROLE(), issuer)) {
            ragaRegistry.grantRole(ragaRegistry.LICENSOR_ROLE(), issuer);
        }
    }

    function _createLineage(address teacher) internal returns (bytes32 uid) {
        if (!ragaRegistry.hasRole(ragaRegistry.LINEAGE_ATTESTER_ROLE(), performer)) {
            ragaRegistry.grantRole(ragaRegistry.LINEAGE_ATTESTER_ROLE(), performer);
        }
        vm.prank(performer);
        ragaRegistry.proposeTeacher(teacher, TEACHER_SHARE_BPS);
        vm.prank(teacher);
        uid = ragaRegistry.acceptStudent(performer);
    }

    function _issueLicense(uint64 expirationTime) internal returns (bytes32 uid) {
        _grantLicensorRole();
        vm.prank(issuer);
        uid = ragaRegistry.issueLicense(ASSET_ID, performer, licensee, expirationTime);
    }
}
