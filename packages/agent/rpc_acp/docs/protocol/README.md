# ACP protocol snapshots

`schema-v1.29.1/` is an unmodified snapshot of the upstream schema release
[`schema-v1.29.1`](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.29.1),
commit `0fc18323a9fdad4e5b4a20ec2f1645dde843fd9b`. The upstream project
licenses these files under Apache-2.0; the license is included in the snapshot.

`schema-v2.0.0-alpha.13/` is a separate snapshot of the upstream
[`schema-v2.0.0-alpha.13`](https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-alpha.13)
tag. It points to the same commit, so its files are currently byte-identical
to those in `schema-v1.29.1/`. Both tag directories are kept to make each
release track independently addressable in conformance checks. The tag names
identify schema release tracks; `v1/` and `v2/` identify protocol versions
within a tag.

Both protocol versions are retained. Each directory contains the stable and
unstable JSON schemas, their metadata, and the upstream schema changelog.
The JSON schemas are the wire-format reference. The changelogs explain changes
between schema releases; they are not substitutes for comparing schemas.

## Updating the snapshot

1. Clone the exact upstream schema tag into a temporary directory.
2. Copy `schema/v1` and `schema/v2` files listed above into a new
   `schema-vX.Y.Z/` directory, along with upstream `LICENSE`. Do not edit the
   copied files.
3. Record the tag and full commit hash here. Keep older snapshots so changes
   can be reviewed against the version currently implemented.
4. Compare both stable schemas with the preceding snapshot, then update the
   version negotiation, wire models, client, and tests together. Review
   unstable schemas separately; their presence here does not imply support.
5. Validate JSON parsing and compare hashes of copied files against the tag.
   Run package analysis and tests with `fvm dart`.

Snapshot availability does not imply `rpc_acp` implements every definition.
The code currently requests protocol version 1 by default; check the code and
tests before claiming compliance with a particular snapshot.

## Local checks

From the repository root, `melos run check:acp-methods` checks that every
method listed in the stable v1 and v2 metadata appears in the wire code. This
is an inventory guard, not a payload or behavior test.

`melos run check:acp-wire` creates a package-local Python venv, installs the
pinned Draft 2020-12 validator, captures messages through `AcpClient` and
its in-memory peer, and checks them against both stable schemas. It is part of
`prepare`. The validator checks method-specific request parameters, direction,
and correlated response payloads. Its negative tests verify required fields,
unknown methods, wrong direction, and missing responses.
Every probe is checked against v1 and v2 under each of the two release tags.
Passing runs retain their two NDJSON traces and a JSON manifest of schema and
trace SHA-256 hashes under `.dart_tool/acp-schema-reports/`. CI uploads these
for independent inspection.

The client probe captures outbound calls from `AcpClient` through the public
`AcpMemoryConnections` pair. It covers 13 methods per version. It captures an
initialize response but uses synthetic responses for other calls. Schema
validation of agent-originated requests and notifications is no longer part of
this gate. Client handling of those messages is covered by package tests and
the external client check below. A passing gate covers only its exercised paths.

## Independent client compatibility check

`melos run check:acp-client` tests the Dart `AcpClient` against independent v1
and v2 conforming fixture agents from the same pinned TCK commit. It checks
negotiation, session creation and listing, prompt completion and updates, and
resume over real stdio processes. The source checkout is kept under
`.dart_tool/` and its commit is verified before use.
