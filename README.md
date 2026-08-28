# RagaLineage

Foundry workspace for Road To Devcon II: **Who Taught You That Raga?**

Verified lineage, commercial-license validity, and royalty calculation are implemented and tested
against genuine EAS contracts. ETH payout execution is intentionally not implemented.

## Minimal architecture

- `RagaRegistry` uses OpenZeppelin `AccessControl` and the official EAS contracts.
- A student with `LINEAGE_ATTESTER_ROLE` proposes one `student -> teacher` edge. The pending proposal
  is only workflow state and is not verified lineage.
- Only the exact proposed teacher can accept. Acceptance creates the authoritative EAS lineage
  attestation containing `student`, `teacher`, and `teacherShareBps`.
- Confirmation also verifies that the student still has `LINEAGE_ATTESTER_ROLE`, making the EAS
  lineage-creation path visibly role-gated without redundant performer and teacher roles.
- The registry is the EAS attester. A teacher can call the registry's authorization-checked revoke
  function, after which the registry revokes the teacher's confirmed edge in EAS.
- Each student has at most one current verified teacher, producing a bounded linear guru chain.
  Teacher acceptance walks the live upstream EAS chain and rejects edges that would create a cycle.
- An explicitly granted `LICENSOR_ROLE` issues a commercial-license EAS attestation for an
  `assetId + licensee` pair. The attestation captures the performer's exact lineage UID.
- License indexes and original-issuer metadata are discovery and revocation-authority data only.
  License validity is recalculated from the current license and captured lineage EAS records.
- License states distinguish `Unlicensed`, `Active`, `Expired`, `Revoked`, and `InvalidLineage`.
- The original issuer alone can ask the registry to revoke a license through genuine EAS revocation.
- Mappings may hold pending proposals and index EAS UIDs for discovery, but EAS attestations remain
  authoritative for confirmed lineage and license validity.
- Lineage and license state read current EAS revocation and expiration data at query time.
- Standalone royalty resolution follows the performer's current EAS-backed lineage. Licensed
  resolution first requires the license's live state to be `Active`, preventing a replacement
  lineage from reviving an old license tied to a revoked edge.

## Cascading royalties

At each `student -> teacher` edge, the student keeps the remainder after their recorded
`teacherShareBps`; only the teacher portion continues upstream. For example:

```text
Devika -> Guru A: 20%
Guru A -> Guru B: 25%
Gross amount:       10,000

Devika keeps:        8,000
Guru A keeps:        1,500
Guru B keeps:          500
Total:              10,000
```

Every hop obtains the current lineage UID from the discovery index and validates its genuine EAS
attestation. A revoked or expired edge is therefore ignored immediately. Integer division rounds
the teacher portion down, leaving dust with the current student and conserving the exact gross
amount. Zero-amount entries are omitted.

Traversal is linear and capped at 16 edges. A chain ending at that boundary resolves normally; an
additional active upstream edge causes `LineageDepthExceeded` rather than returning a truncated
allocation. These functions calculate allocations only and never transfer ETH.

## EAS schemas

```text
address student,address teacher,uint16 teacherShareBps
bytes32 assetId,address performer,address licensee,bytes32 lineageUID
```

## Official scored checks

1. Teacher confirmation is required for a verified lineage claim.
2. License validity is read from current attestation state at time of use.
3. Genuine EAS schemas and attestations are used.
4. Royalty shares are resolved through the lineage graph.
5. License or lineage revocation changes subsequent license state.
6. Creating lineage claims is role-gated.
7. Unlicensed and expired/revoked states are distinguishable.
8. Tracked files contain no credentials.

## Toolchain

- Foundry `1.8.1`
- forge-std `v1.16.2`
- OpenZeppelin Contracts `v5.7.0`
- EAS Contracts `v1.4.0`
- Solidity `0.8.28`

## Commands

```sh
forge fmt --check
forge build
forge test
```

Copy `.env.example` to an untracked `.env` only when deployment work begins. Never commit secrets.
