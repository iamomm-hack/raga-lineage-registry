// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    Attestation,
    EMPTY_UID,
    NO_EXPIRATION_TIME
} from "@ethereum-attestation-service/eas-contracts/contracts/Common.sol";
import {
    AttestationRequest,
    AttestationRequestData,
    IEAS,
    RevocationRequest,
    RevocationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";

/// @title RagaRegistry
/// @notice Records verified lineage and commercial licenses through Ethereum Attestation Service.
/// @dev A proposal is only workflow state. A lineage becomes authoritative only after the exact
///      proposed teacher accepts and this contract creates the EAS attestation. EAS therefore
///      records this registry as the attester; teacher authorization is transactionally enforced
///      by the exact msg.sender checks in acceptStudent and revokeLineage.
contract RagaRegistry is AccessControl {
    /// @notice Role required for a student to propose a lineage edge.
    bytes32 public constant LINEAGE_ATTESTER_ROLE = keccak256("LINEAGE_ATTESTER_ROLE");

    /// @notice Role permitted to issue commercial licenses.
    bytes32 public constant LICENSOR_ROLE = keccak256("LICENSOR_ROLE");

    uint16 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_LINEAGE_DEPTH = 16;

    enum LineageState {
        None,
        Pending,
        Active,
        Revoked,
        Expired
    }

    enum LicenseState {
        Unlicensed,
        Active,
        Expired,
        Revoked,
        InvalidLineage
    }

    struct PendingProposal {
        address teacher;
        uint16 teacherShareBps;
    }

    struct RoyaltyAllocation {
        address recipient;
        uint256 amount;
    }

    error InvalidEAS();
    error InvalidSchemaUID();
    error ZeroTeacher();
    error SelfTeaching();
    error InvalidTeacherShare(uint16 teacherShareBps);
    error PendingProposalExists(address student);
    error NoPendingProposal(address student);
    error NotProposedTeacher(address caller, address proposedTeacher);
    error ActiveLineageExists(address student);
    error NoVerifiedLineage(address student);
    error InvalidLineageAttestation(bytes32 uid);
    error LineageNotActive(address student, LineageState state);
    error NotLineageTeacher(address caller, address teacher);
    error ZeroAssetId();
    error ZeroPerformer();
    error ZeroLicensee();
    error InvalidLicenseExpiration(uint64 expirationTime);
    error PerformerLineageNotActive(address performer);
    error ActiveLicenseExists(bytes32 assetId, address licensee);
    error NoCommercialLicense(bytes32 assetId, address licensee);
    error InvalidLicenseAttestation(bytes32 uid);
    error NotLicenseIssuer(address caller, address issuer);
    error LicenseAlreadyRevoked(bytes32 uid);
    error LicenseNotActiveForRoyalties(LicenseState state);
    error LineageDepthExceeded();
    error LineageCycle(address student, address teacher);

    event TeacherProposed(address indexed student, address indexed teacher, uint16 teacherShareBps);
    event LineageAccepted(
        address indexed student,
        address indexed teacher,
        bytes32 indexed uid,
        uint16 teacherShareBps
    );
    event LineageRevoked(address indexed student, address indexed teacher, bytes32 indexed uid);
    event LicenseIssued(
        bytes32 indexed assetId,
        address indexed licensee,
        address indexed performer,
        bytes32 uid,
        bytes32 lineageUID,
        address issuer,
        uint64 expirationTime
    );
    event LicenseRevoked(
        bytes32 indexed assetId, address indexed licensee, bytes32 indexed uid, address issuer
    );

    IEAS public immutable eas;
    bytes32 public immutable lineageSchemaUID;
    bytes32 public immutable licenseSchemaUID;

    // Workflow/index metadata only. All accepted lineage and license validity comes from live EAS
    // attestations loaded through these discovery UIDs, never from a cached validity flag.
    mapping(address student => PendingProposal proposal) private _pendingProposals;
    mapping(address student => bytes32 uid) private _lineageUIDs;
    mapping(bytes32 assetId => mapping(address licensee => bytes32 uid)) private _licenseUIDs;
    // Authorization metadata only: EAS revocation/expiration remains authoritative for state.
    mapping(bytes32 uid => address issuer) private _licenseIssuers;

    /// @param eas_ Official Ethereum Attestation Service contract.
    /// @param lineageSchemaUID_ UID for `address student,address teacher,uint16 teacherShareBps`.
    /// @param licenseSchemaUID_ UID for
    ///        `bytes32 assetId,address performer,address licensee,bytes32 lineageUID`.
    constructor(IEAS eas_, bytes32 lineageSchemaUID_, bytes32 licenseSchemaUID_) {
        if (address(eas_) == address(0)) revert InvalidEAS();
        if (lineageSchemaUID_ == EMPTY_UID || licenseSchemaUID_ == EMPTY_UID) {
            revert InvalidSchemaUID();
        }

        eas = eas_;
        lineageSchemaUID = lineageSchemaUID_;
        licenseSchemaUID = licenseSchemaUID_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Proposes the caller's teacher and requested upstream royalty share.
    /// @dev This creates no EAS attestation and does not establish verified lineage.
    /// @param teacher Proposed teacher who must later accept the student.
    /// @param teacherShareBps Teacher share in basis points, capped at 10,000.
    function proposeTeacher(address teacher, uint16 teacherShareBps)
        external
        onlyRole(LINEAGE_ATTESTER_ROLE)
    {
        if (teacher == address(0)) revert ZeroTeacher();
        if (teacher == msg.sender) revert SelfTeaching();
        if (teacherShareBps > MAX_BPS) revert InvalidTeacherShare(teacherShareBps);
        if (_pendingProposals[msg.sender].teacher != address(0)) {
            revert PendingProposalExists(msg.sender);
        }
        if (lineageState(msg.sender) == LineageState.Active) {
            revert ActiveLineageExists(msg.sender);
        }

        _pendingProposals[msg.sender] =
            PendingProposal({ teacher: teacher, teacherShareBps: teacherShareBps });

        emit TeacherProposed(msg.sender, teacher, teacherShareBps);
    }

    /// @notice Accepts a pending student and creates their authoritative EAS lineage attestation.
    /// @dev EAS records this registry as attester. The actual teacher is authenticated by requiring
    ///      msg.sender to equal the exact teacher stored in the student's pending proposal.
    /// @param student Student whose pending proposal is being accepted.
    /// @return uid UID of the newly created EAS attestation.
    function acceptStudent(address student) external returns (bytes32 uid) {
        PendingProposal memory proposal = _pendingProposals[student];
        if (proposal.teacher == address(0)) revert NoPendingProposal(student);
        if (msg.sender != proposal.teacher) {
            revert NotProposedTeacher(msg.sender, proposal.teacher);
        }

        _checkRole(LINEAGE_ATTESTER_ROLE, student);
        if (lineageState(student) == LineageState.Active) {
            revert ActiveLineageExists(student);
        }
        _validateLineageExtension(student, proposal.teacher);

        // Clear workflow state before the external EAS call. A revert rolls this deletion back.
        delete _pendingProposals[student];

        uid = eas.attest(
            AttestationRequest({
                schema: lineageSchemaUID,
                data: AttestationRequestData({
                    recipient: student,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refUID: EMPTY_UID,
                    data: abi.encode(student, proposal.teacher, proposal.teacherShareBps),
                    value: 0
                })
            })
        );

        _lineageUIDs[student] = uid;
        emit LineageAccepted(student, proposal.teacher, uid, proposal.teacherShareBps);
    }

    /// @notice Revokes a student's accepted lineage in EAS.
    /// @dev Only the teacher encoded in the live EAS attestation can initiate this registry call.
    ///      The registry calls EAS because EAS correctly records the registry as the attester.
    /// @param student Student whose current lineage should be revoked.
    function revokeLineage(address student) external {
        (bytes32 uid, address teacher,, LineageState state, bool structurallyValid) =
            _readLineage(student);

        if (uid == EMPTY_UID) revert NoVerifiedLineage(student);
        if (!structurallyValid) revert InvalidLineageAttestation(uid);
        if (msg.sender != teacher) revert NotLineageTeacher(msg.sender, teacher);
        if (state != LineageState.Active) revert LineageNotActive(student, state);

        eas.revoke(
            RevocationRequest({
                schema: lineageSchemaUID, data: RevocationRequestData({ uid: uid, value: 0 })
            })
        );

        emit LineageRevoked(student, teacher, uid);
    }

    /// @notice Returns the student's current lineage state from live EAS data.
    /// @param student Student to query.
    /// @return Current state, including EAS revocation and expiration.
    function lineageState(address student) public view returns (LineageState) {
        (bytes32 uid,,, LineageState state, bool structurallyValid) = _readLineage(student);
        if (uid == EMPTY_UID) {
            return _pendingProposals[student].teacher == address(0)
                ? LineageState.None
                : LineageState.Pending;
        }

        return structurallyValid ? state : LineageState.None;
    }

    /// @notice Checks whether a student has an active lineage attestation right now.
    /// @param student Student to query.
    function hasValidLineage(address student) external view returns (bool) {
        return lineageState(student) == LineageState.Active;
    }

    /// @notice Returns the indexed UID, decoded lineage data, and current live EAS state.
    /// @param student Student to query.
    /// @return uid Indexed EAS attestation UID.
    /// @return teacher Teacher decoded from EAS data.
    /// @return teacherShareBps Teacher share decoded from EAS data.
    /// @return state Current lineage state determined from EAS.
    function getLineage(address student)
        external
        view
        returns (bytes32 uid, address teacher, uint16 teacherShareBps, LineageState state)
    {
        bool structurallyValid;
        (uid, teacher, teacherShareBps, state, structurallyValid) = _readLineage(student);

        if (uid == EMPTY_UID) {
            state = _pendingProposals[student].teacher == address(0)
                ? LineageState.None
                : LineageState.Pending;
        } else if (!structurallyValid) {
            teacher = address(0);
            teacherShareBps = 0;
            state = LineageState.None;
        }
    }

    /// @notice Returns a student's unresolved proposal.
    function getPendingProposal(address student)
        external
        view
        returns (address teacher, uint16 teacherShareBps, bool exists)
    {
        PendingProposal memory proposal = _pendingProposals[student];
        return (proposal.teacher, proposal.teacherShareBps, proposal.teacher != address(0));
    }

    /// @notice Issues a revocable commercial license backed by the performer's current lineage.
    /// @dev The indexed UID is discovery-only. EAS remains authoritative for all validity checks.
    /// @param assetId Recording or composition identifier.
    /// @param performer Performer whose verified lineage backs this license.
    /// @param licensee Recipient of the commercial license.
    /// @param expirationTime Unix timestamp at which the license becomes expired.
    /// @return uid UID of the genuine EAS license attestation.
    function issueLicense(
        bytes32 assetId,
        address performer,
        address licensee,
        uint64 expirationTime
    ) external onlyRole(LICENSOR_ROLE) returns (bytes32 uid) {
        if (assetId == EMPTY_UID) revert ZeroAssetId();
        if (performer == address(0)) revert ZeroPerformer();
        if (licensee == address(0)) revert ZeroLicensee();
        if (expirationTime <= block.timestamp) {
            revert InvalidLicenseExpiration(expirationTime);
        }
        if (licenseState(assetId, licensee) == LicenseState.Active) {
            revert ActiveLicenseExists(assetId, licensee);
        }

        (bytes32 lineageUID,,, LineageState currentLineageState, bool structurallyValid) =
            _readLineage(performer);
        if (!structurallyValid || currentLineageState != LineageState.Active) {
            revert PerformerLineageNotActive(performer);
        }

        uid = eas.attest(
            AttestationRequest({
                schema: licenseSchemaUID,
                data: AttestationRequestData({
                    recipient: licensee,
                    expirationTime: expirationTime,
                    revocable: true,
                    refUID: EMPTY_UID,
                    data: abi.encode(assetId, performer, licensee, lineageUID),
                    value: 0
                })
            })
        );

        _licenseUIDs[assetId][licensee] = uid;
        _licenseIssuers[uid] = msg.sender;
        emit LicenseIssued(
            assetId, licensee, performer, uid, lineageUID, msg.sender, expirationTime
        );
    }

    /// @notice Returns the current license state using live license and lineage EAS records.
    /// @dev State precedence is Unlicensed, then Revoked, Expired, InvalidLineage, or Active.
    function licenseState(bytes32 assetId, address licensee) public view returns (LicenseState) {
        (bytes32 uid,,,, LicenseState state, bool structurallyValid) =
            _readLicense(assetId, licensee);
        if (uid == EMPTY_UID || !structurallyValid) return LicenseState.Unlicensed;
        return state;
    }

    /// @notice Checks whether the discovered commercial license is active right now.
    function isLicenseValid(bytes32 assetId, address licensee) external view returns (bool) {
        return licenseState(assetId, licensee) == LicenseState.Active;
    }

    /// @notice Returns discovered license data and its state from current EAS records.
    function getLicense(bytes32 assetId, address licensee)
        external
        view
        returns (
            bytes32 uid,
            address performer,
            bytes32 lineageUID,
            uint64 expirationTime,
            LicenseState state
        )
    {
        bool structurallyValid;
        (uid, performer, lineageUID, expirationTime, state, structurallyValid) =
            _readLicense(assetId, licensee);
        if (!structurallyValid) {
            performer = address(0);
            lineageUID = EMPTY_UID;
            expirationTime = 0;
            state = LicenseState.Unlicensed;
        }
    }

    /// @notice Revokes the discovered genuine EAS license attestation.
    /// @dev The original issuer remains the sole revocation authority even if their role changes.
    function revokeLicense(bytes32 assetId, address licensee) external {
        (bytes32 uid,,,, LicenseState state, bool structurallyValid) =
            _readLicense(assetId, licensee);
        if (uid == EMPTY_UID) revert NoCommercialLicense(assetId, licensee);
        if (!structurallyValid) revert InvalidLicenseAttestation(uid);

        address issuer = _licenseIssuers[uid];
        if (msg.sender != issuer) revert NotLicenseIssuer(msg.sender, issuer);
        if (state == LicenseState.Revoked) revert LicenseAlreadyRevoked(uid);

        eas.revoke(
            RevocationRequest({
                schema: licenseSchemaUID, data: RevocationRequestData({ uid: uid, value: 0 })
            })
        );

        emit LicenseRevoked(assetId, licensee, uid, issuer);
    }

    /// @notice Resolves a gross royalty amount over the performer's current verified lineage.
    /// @dev Every hop reads the current indexed UID and genuine EAS attestation. No payout occurs.
    ///      Zero-valued recipient entries are omitted and a zero gross amount returns an empty array.
    function resolveRoyalties(address performer, uint256 grossAmount)
        external
        view
        returns (RoyaltyAllocation[] memory allocations)
    {
        if (performer == address(0)) revert ZeroPerformer();
        return _resolveRoyalties(performer, grossAmount);
    }

    /// @notice Resolves royalties only when the discovered commercial license is active right now.
    /// @dev The active-state check validates the license's captured lineage UID before traversal,
    ///      preventing a replacement lineage from reviving an old invalid license.
    function resolveLicensedRoyalties(bytes32 assetId, address licensee, uint256 grossAmount)
        external
        view
        returns (RoyaltyAllocation[] memory allocations)
    {
        LicenseState currentLicenseState = licenseState(assetId, licensee);
        if (currentLicenseState != LicenseState.Active) {
            revert LicenseNotActiveForRoyalties(currentLicenseState);
        }

        (, address performer,,,,) = _readLicense(assetId, licensee);
        return _resolveRoyalties(performer, grossAmount);
    }

    function _readLineage(address student)
        private
        view
        returns (
            bytes32 uid,
            address teacher,
            uint16 teacherShareBps,
            LineageState state,
            bool structurallyValid
        )
    {
        uid = _lineageUIDs[student];
        if (uid == EMPTY_UID) return (uid, teacher, teacherShareBps, state, false);

        (teacher, teacherShareBps, state, structurallyValid) = _readLineageUID(uid, student);
    }

    function _resolveRoyalties(address performer, uint256 grossAmount)
        private
        view
        returns (RoyaltyAllocation[] memory allocations)
    {
        if (grossAmount == 0) return new RoyaltyAllocation[](0);

        RoyaltyAllocation[] memory pending = new RoyaltyAllocation[](MAX_LINEAGE_DEPTH + 1);
        uint256 allocationCount = 0;
        address currentNode = performer;
        uint256 incomingAmount = grossAmount;

        for (uint256 depth = 0; depth < MAX_LINEAGE_DEPTH; ++depth) {
            (, address teacher, uint16 teacherShareBps, LineageState state, bool validStructure) =
                _readLineage(currentNode);

            if (!validStructure || state != LineageState.Active) {
                pending[allocationCount++] =
                    RoyaltyAllocation({ recipient: currentNode, amount: incomingAmount });
                return _copyAllocations(pending, allocationCount);
            }

            uint256 teacherAmount = Math.mulDiv(incomingAmount, teacherShareBps, MAX_BPS);
            uint256 studentAmount = incomingAmount - teacherAmount;
            if (studentAmount != 0) {
                pending[allocationCount++] =
                    RoyaltyAllocation({ recipient: currentNode, amount: studentAmount });
            }

            if (teacherAmount == 0) return _copyAllocations(pending, allocationCount);

            currentNode = teacher;
            incomingAmount = teacherAmount;
        }

        // MAX_LINEAGE_DEPTH edges were processed. The terminal node may retain the remainder only
        // if it has no further active EAS-backed edge; otherwise the result would be truncated.
        (,,, LineageState terminalState, bool validTerminalStructure) = _readLineage(currentNode);
        if (validTerminalStructure && terminalState == LineageState.Active) {
            revert LineageDepthExceeded();
        }

        pending[allocationCount++] =
            RoyaltyAllocation({ recipient: currentNode, amount: incomingAmount });
        return _copyAllocations(pending, allocationCount);
    }

    function _validateLineageExtension(address student, address teacher) private view {
        address currentNode = teacher;

        // Acceptance of student -> teacher must not close a cycle through the teacher's current,
        // genuine EAS-backed upstream chain. Overlong chains are rejected conservatively because
        // they cannot produce an authoritative bounded royalty resolution.
        for (uint256 depth = 0; depth < MAX_LINEAGE_DEPTH; ++depth) {
            if (currentNode == student) revert LineageCycle(student, teacher);

            (, address upstreamTeacher,, LineageState state, bool validStructure) =
                _readLineage(currentNode);
            if (!validStructure || state != LineageState.Active) return;
            currentNode = upstreamTeacher;
        }

        if (currentNode == student) revert LineageCycle(student, teacher);
        revert LineageDepthExceeded();
    }

    function _copyAllocations(RoyaltyAllocation[] memory source, uint256 count)
        private
        pure
        returns (RoyaltyAllocation[] memory allocations)
    {
        allocations = new RoyaltyAllocation[](count);
        for (uint256 i = 0; i < count; ++i) {
            allocations[i] = source[i];
        }
    }

    function _readLineageUID(bytes32 uid, address student)
        private
        view
        returns (
            address teacher,
            uint16 teacherShareBps,
            LineageState state,
            bool structurallyValid
        )
    {
        Attestation memory attestation = eas.getAttestation(uid);
        if (
            attestation.uid != uid || attestation.schema != lineageSchemaUID
                || attestation.recipient != student || attestation.attester != address(this)
                || attestation.data.length != 96
        ) {
            return (teacher, teacherShareBps, LineageState.None, false);
        }

        (address encodedStudent, address encodedTeacher, uint16 encodedShareBps) =
            abi.decode(attestation.data, (address, address, uint16));
        if (
            encodedStudent != student || encodedTeacher == address(0) || encodedTeacher == student
                || encodedShareBps > MAX_BPS
        ) {
            return (teacher, teacherShareBps, LineageState.None, false);
        }

        teacher = encodedTeacher;
        teacherShareBps = encodedShareBps;
        structurallyValid = true;

        if (attestation.revocationTime != 0) {
            state = LineageState.Revoked;
        } else if (
            attestation.expirationTime != NO_EXPIRATION_TIME
                && attestation.expirationTime <= block.timestamp
        ) {
            state = LineageState.Expired;
        } else {
            state = LineageState.Active;
        }
    }

    function _readLicense(bytes32 assetId, address licensee)
        private
        view
        returns (
            bytes32 uid,
            address performer,
            bytes32 lineageUID,
            uint64 expirationTime,
            LicenseState state,
            bool structurallyValid
        )
    {
        uid = _licenseUIDs[assetId][licensee];
        if (uid == EMPTY_UID) {
            return (uid, performer, lineageUID, expirationTime, LicenseState.Unlicensed, false);
        }

        Attestation memory attestation = eas.getAttestation(uid);
        if (
            attestation.uid != uid || attestation.schema != licenseSchemaUID
                || attestation.recipient != licensee || attestation.attester != address(this)
                || !attestation.revocable || attestation.data.length != 128
        ) {
            return (uid, performer, lineageUID, expirationTime, LicenseState.Unlicensed, false);
        }

        bytes32 encodedAssetId;
        address encodedLicensee;
        (encodedAssetId, performer, encodedLicensee, lineageUID) =
            abi.decode(attestation.data, (bytes32, address, address, bytes32));
        if (
            encodedAssetId != assetId || performer == address(0) || encodedLicensee != licensee
                || lineageUID == EMPTY_UID
        ) {
            return (uid, address(0), EMPTY_UID, 0, LicenseState.Unlicensed, false);
        }

        expirationTime = attestation.expirationTime;
        structurallyValid = true;

        if (attestation.revocationTime != 0) {
            state = LicenseState.Revoked;
        } else if (expirationTime != NO_EXPIRATION_TIME && expirationTime <= block.timestamp) {
            state = LicenseState.Expired;
        } else {
            (,, LineageState capturedLineageState, bool validLineageStructure) =
                _readLineageUID(lineageUID, performer);
            state = validLineageStructure && capturedLineageState == LineageState.Active
                ? LicenseState.Active
                : LicenseState.InvalidLineage;
        }
    }
}
