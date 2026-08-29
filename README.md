# RagaLineage

**EAS-powered licensing that keeps guru-shishya lineage and upstream royalties alive.**

RagaLineage is an EAS-backed registry for **Who Taught You That Raga?** at Road To Devcon II. It
models verified guru-shishya lineage, commercial licenses that depend on that lineage, and
multi-generation royalty calculations.

## 🚀 Live Base Sepolia Deployment

> RagaLineage is live on Base Sepolia and uses the official EAS and SchemaRegistry predeploys — not
> mocks.

**Network:** Base Sepolia

**Chain ID:** `84532`

| Contract | Address |
| --- | --- |
| RagaRegistry | [`0x456a2E96430C31172Ca2f602D07b69fe0767B96a`](https://sepolia.basescan.org/address/0x456a2E96430C31172Ca2f602D07b69fe0767B96a) |
| Official EAS | [`0x4200000000000000000000000000000000000021`](https://sepolia.basescan.org/address/0x4200000000000000000000000000000000000021) |
| Official SchemaRegistry | [`0x4200000000000000000000000000000000000020`](https://sepolia.basescan.org/address/0x4200000000000000000000000000000000000020) |

### EAS Schemas

| Schema | UID | Resolver | Revocable |
| --- | --- | --- | --- |
| Lineage | `0xf044cb02b336aaa598c4d2f8530abcbf5cbfb401d87fb90f8a390975319a06bf` | Zero address | Yes |
| Commercial license | `0x1da6bebc9d2bf5b7d427cac869f6a876cdd5ce0f29c1a8c729f3c89d0dba6c47` | Zero address | Yes |

**Deployment transaction:**
[`0x50742e...96766`](https://sepolia.basescan.org/tx/0x50742ea97db7bdbcb7df79c08dd025350541f298883e406eed5ed00c0e296766)

Public deployment metadata:
[`deployments/base-sepolia.json`](deployments/base-sepolia.json)

Fresh RPC reads verified the deployed runtime bytecode, official EAS address, both immutable schema
UIDs, both SchemaRegistry records, and the deployer's `DEFAULT_ADMIN_ROLE`. The live deployment uses
the genuine official EAS and SchemaRegistry predeploys, not local mocks.

The reproducible workflow in `script/DeployBaseSepolia.s.sol` uses untracked `PRIVATE_KEY` and
`BASE_SEPOLIA_RPC_URL` values and rejects non-Base-Sepolia chain IDs. Neither credentials nor
Foundry broadcast/cache output are tracked.

## Judge Quick Start

```bash
git clone --recurse-submodules https://github.com/iamomm-hack/raga-lineage-registry
cd raga-lineage-registry
forge test
```

Expected: `46 passed, 0 failed, 0 skipped`.

Review the core contract in [`src/RagaRegistry.sol`](src/RagaRegistry.sol), then the focused
[`lineage`](test/RagaRegistry.Lineage.t.sol), [`license`](test/RagaRegistry.License.t.sol), and
[`royalty`](test/RagaRegistry.Royalty.t.sol) test suites. Live public addresses and schema UIDs are
recorded in [`deployments/base-sepolia.json`](deployments/base-sepolia.json).

## 60-Second Demo

1. The admin grants `LINEAGE_ATTESTER_ROLE` to Devika; Devika calls
   `proposeTeacher(guruA, 2_000)`.
2. Guru A calls `acceptStudent(devika)`, causing `RagaRegistry` to create a genuine lineage EAS
   attestation.
3. The admin grants `LICENSOR_ROLE`; the licensor calls
   `issueLicense(assetId, devika, platform, expiry)`.
4. `licenseState(assetId, platform)` returns `Active`, and
   `resolveLicensedRoyalties(assetId, platform, 10_000)` derives recipients from EAS lineage.
5. For `Devika -> Guru A = 20%` and `Guru A -> Guru B = 25%`, the allocations are Devika `8,000`,
   Guru A `1,500`, and Guru B `500`.
6. Guru A calls `revokeLineage(devika)`; the same license now returns `InvalidLineage`, and
   `isLicenseValid(assetId, platform)` returns `false`.

## Why RagaLineage

Traditional licensing usually pays the performer it can identify. That loses the teaching lineage
that shaped the performance and gives a platform no reliable way to distinguish a real teacher
relationship from a unilateral claim. RagaLineage makes the lineage graph load-bearing: teachers
must confirm claims, licenses are valid only while their captured lineage remains valid, and royalty
recipients are calculated from the current verified graph.

## What is implemented

- Teacher-confirmed, role-gated `student -> teacher` lineage attestations.
- Genuine Ethereum Attestation Service schemas, attestations, reads, and revocations.
- Commercial licenses indexed by `assetId + licensee`, with live expiry and revocation checks.
- License invalidation when the exact lineage UID captured at issuance is no longer valid.
- Bounded, cycle-safe, multi-hop royalty calculation with exact amount conservation.
- 46 Foundry tests using real local `EAS` and `SchemaRegistry` contracts.

Mappings only locate pending workflows and EAS UIDs. They never cache whether lineage or a license
is valid; current EAS attestations are the source of truth.

## Architecture

```text
Student with LINEAGE_ATTESTER_ROLE
  |
  | proposeTeacher(teacher, shareBps)
  v
Pending proposal (not verified lineage)
  |
  | exact proposed teacher calls acceptStudent(student)
  v
RagaRegistry ---------------------------------------------------+
  |                                                            |
  | EAS.attest(lineage schema)                                 | resolveRoyalties()
  v                                                            |
Verified lineage attestation                                   |
  |                                                            |
  | issueLicense() requires active lineage                     |
  v                                                            v
Commercial license attestation                         Live EAS lineage traversal
  |                                                    Performer -> Guru -> Guru's Guru
  | licenseState() reads license + captured lineage
  v
Unlicensed / Active / Expired / Revoked / InvalidLineage
```

The registry is the EAS `attester` because it calls EAS. Teacher authorization is nevertheless
transactionally real: only the exact teacher stored in the pending proposal can trigger the lineage
attestation. Direct third-party attestations are ignored because valid records must be indexed by
the registry and have `attester == address(RagaRegistry)`.

## Attest -> License -> Check -> Revoke

1. **Student proposes a teacher.** A student granted `LINEAGE_ATTESTER_ROLE` calls
   `proposeTeacher`. This stores pending workflow data only; `hasValidLineage` remains false.
2. **The exact teacher confirms.** The proposed teacher calls `acceptStudent`. The function checks
   the caller, rechecks the student's role, rejects cycles, and exposes no bypass for an admin or a
   different teacher.
3. **The registry creates genuine EAS lineage.** `acceptStudent` calls `IEAS.attest` with the lineage
   schema, the student as recipient, the registry as EAS attester, and ABI-encoded student, teacher,
   and share data. The revocable EAS record becomes authoritative.
4. **A licensor issues a commercial license.** An account granted `LICENSOR_ROLE` calls
   `issueLicense`. The performer must have active lineage. The license records its expiration and
   captures the performer's exact current lineage UID; it cannot silently switch to a replacement.
5. **Anyone checks current validity.** `licenseState` and `isLicenseValid` reread the license EAS
   record and its captured lineage EAS record on every call. There is no cached validity boolean.
6. **The teacher revokes lineage.** `revokeLineage` authorizes the encoded teacher and calls genuine
   `IEAS.revoke`. A dependent, otherwise-unrevoked license immediately becomes `InvalidLineage`.

The original license issuer can independently call `revokeLicense`, making its live state
`Revoked`. Reaching the EAS expiration timestamp makes it `Expired`; a never-issued pair remains
`Unlicensed`.

## EAS schemas

### Lineage

```text
address student,address teacher,uint16 teacherShareBps
```

| Field | Meaning |
| --- | --- |
| `student` | Performer or teacher whose upstream relationship is being verified |
| `teacher` | Exact teacher who transactionally accepted the relationship |
| `teacherShareBps` | Share of value arriving at the student that moves one generation upstream |

The student is the EAS recipient. The registry is the EAS attester. Lineage attestations are
revocable and non-expiring, while readers still validate both revocation and expiration metadata.

### Commercial license

```text
bytes32 assetId,address performer,address licensee,bytes32 lineageUID
```

| Field | Meaning |
| --- | --- |
| `assetId` | Recording or composition identifier |
| `performer` | Performer whose verified lineage backs the license |
| `licensee` | Commercial user and EAS recipient |
| `lineageUID` | Exact verified lineage attestation captured when the license was issued |

License expiry lives in EAS attestation metadata rather than encoded schema data. Licenses are
revocable, and live EAS state remains authoritative for `Active`, `Expired`, `Revoked`, and
`InvalidLineage` outcomes.

## Cascading royalties

At each active `student -> teacher` edge:

```text
teacherAmount = incomingAmount * teacherShareBps / 10,000
studentAmount = incomingAmount - teacherAmount
```

Only `teacherAmount` continues upstream. For the tested example:

```text
Devika -> Guru A: 20%
Guru A -> Guru B: 25%
Gross royalty: 10,000

Devika: 8,000
Guru A: 1,500
Guru B:   500
Total: 10,000
```

Solidity integer division rounds the teacher portion down, so dust stays with the current node and
allocations always sum to the gross amount. Zero-value entries are omitted. Standalone
`resolveRoyalties` follows the current graph and stops at revoked, expired, or invalid edges.
`resolveLicensedRoyalties` first requires the license's live state to be `Active`.

Traversal is bounded at `MAX_LINEAGE_DEPTH == 16`. A chain ending there resolves; another active
upstream edge causes `LineageDepthExceeded` instead of returning an incomplete result.

## Public API

| Function | Purpose |
| --- | --- |
| `proposeTeacher(teacher, shareBps)` | Role-gated student proposal; does not create verified lineage |
| `acceptStudent(student)` | Exact teacher confirmation and genuine EAS lineage attestation |
| `revokeLineage(student)` | Encoded teacher revokes the current lineage through EAS |
| `lineageState(student)` | Returns current EAS-backed lineage state |
| `issueLicense(assetId, performer, licensee, expiry)` | Licensor creates a revocable EAS license tied to current lineage |
| `licenseState(assetId, licensee)` | Returns live license, expiry, revocation, and lineage-dependent state |
| `isLicenseValid(assetId, licensee)` | Convenience check for `LicenseState.Active` |
| `revokeLicense(assetId, licensee)` | Original issuer revokes the indexed license through EAS |
| `resolveRoyalties(performer, amount)` | Calculates allocations from the current lineage graph |
| `resolveLicensedRoyalties(assetId, licensee, amount)` | Requires an active license, then resolves its performer's graph |

## Scored requirements

| Official requirement | Implementation | Direct test evidence |
| --- | --- | --- |
| 1. Teacher confirmation | `proposeTeacher`, `acceptStudent` exact-caller check | `testWrongTeacherCannotAccept`, `testExactTeacherAcceptanceCreatesGenuineEASRecord` |
| 2. Time-of-use license validity | `licenseState`, `_readLicense`, live captured-lineage read | `testExpiryIsCheckedAtTimeOfUse`, `testLicenseRemainsBoundToCapturedLineageUID` |
| 3. Genuine EAS schema | Official `IEAS.attest/revoke/getAttestation`; real schema fixtures | `testExactTeacherAcceptanceCreatesGenuineEASRecord`, `testIssueCreatesGenuineEASLicense` |
| 4. Graph-derived royalties | `resolveRoyalties`, bounded EAS-backed traversal | `testMultiHopLineageCascadesRecordedShares` |
| 5. Revocation changes license state | `revokeLicense` -> `Revoked`; `revokeLineage` -> `InvalidLineage` | `testOriginalIssuerRevocationChangesLiveEASState`, `testTeacherLineageRevocationInvalidatesUnrevokedLicense` |
| 6. Role-gated lineage | `onlyRole(LINEAGE_ATTESTER_ROLE)` plus acceptance-time recheck | `testRoleGatingRejectsUnauthorizedThenAllowsGrantedStudent`, `testStudentRoleIsRecheckedAtAcceptance` |
| 7. Distinct Unlicensed/Expired states | Public `LicenseState` and `licenseState` | `testExpiredDiffersFromNeverLicensed` |
| 8. No tracked credentials | `.env`/broadcast outputs ignored; example values blank | Repository credential scan and `.env.example` inspection |

## Test locally

Prerequisite: [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/iamomm-hack/raga-lineage-registry
cd raga-lineage-registry
forge build
forge test -vvv
```

Expected result at this revision:

```text
46 passed, 0 failed, 0 skipped
```

The tests deploy genuine local EAS and SchemaRegistry contracts and register both schemas. They do
not replace EAS with a mapping mock.

## Intentional scope and limitations

- One current teacher edge per student produces a linear lineage rather than an arbitrary DAG.
- Teacher acceptance prevents cycles; royalty traversal is bounded to 16 active edges.
- Royalty functions calculate allocations only. They do not transfer ETH or maintain balances.
- Official EAS and schema UIDs are immutable constructor configuration and must be verified at
  deployment.
- `DEFAULT_ADMIN_ROLE` grants the roles allowed to propose lineage and issue licenses.
- No frontend or nontechnical query interface is included.
- The Base Sepolia deployer retains `DEFAULT_ADMIN_ROLE`; operational roles are granted explicitly.

## Toolchain

- Solidity `0.8.28`
- Foundry `1.8.1`
- EAS Contracts `v1.4.0`
- OpenZeppelin Contracts `v5.7.0`
- forge-std `v1.16.2`
