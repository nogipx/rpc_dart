---
status: open
round: 318
commit: 935d4bc3
paths: [packages/blob/rpc_blob/lib/src/adapters/**, packages/blob/rpc_blob_webdav/lib/**, packages/blob/rpc_blob_minio/lib/**, packages/blob/rpc_blob_sqlite/lib/**]
probe: none
reason: "owner scope decision (round 318) — refactoring is core and transport only for now; `packages/blob` is neither, and B-10 keeps data/blob/notify deferred"
---

# B-33 — two blob adapters answer a missing blob differently

Found incidentally in round 318 while enumerating surfaces, before the owner
narrowed scope back to core and transport. **Not investigated further and not
fixed.** Filed so a measured contradiction is not lost.

## The contradiction

`IBlobRepository.deleteBlob(collection, id, {expectedVersion})` promises only:

> Delete a blob; returns `true` when something was removed.

Nothing about what a version mismatch or a missing blob does. The two adapters
read side by side answer the SAME input differently:

    input: blob is missing, expectedVersion != null

    in_memory_blob_repository.dart:202   throws StateError
                                         'Expected version N for id but blob is missing.'
    webdav_blob_repository.dart:248      returns false

For a mismatch on an EXISTING blob both throw `StateError`, so the divergence is
specifically the missing-blob case.

## Why it matters for an ecosystem

These are interchangeable by design — the whole point of the interface is that
an application picks a backend. A caller written against `in_memory` in tests
wraps the call in try/catch; the same code on WebDAV silently takes the
`false` branch, or vice versa. Neither adapter is obviously wrong, because the
interface never said.

Two more implementations exist and were NOT compared: `rpc_blob_minio` (S3) and
`rpc_blob_sqlite`. `IDataStorageAdapter` (3 implementations) and
`INotifyRepository` (3) have the same structure and were not looked at at all.

## The aggravating factor

Per `config.md`, `*_postgres` and `*_minio` tests need running services and are
excluded from `melos run test:unit`. So the adapters least likely to be
exercised by the ordinary gate are exactly the ones where this kind of
divergence accumulates unseen.

## What settling it needs

A conformance suite the interface owns and every adapter runs — the same
assertions against each implementation, with the infra-backed ones behind the
existing service-dependent test split. That is a real piece of work and belongs
to whatever round takes B-10 up.

Deciding the SEMANTICS first is the prerequisite and is the owner's: should a
missing blob with an `expectedVersion` throw, or return false? Once that is
written on the interface, the suite is mechanical.

## Owner decision

**Out of scope for now (round 318).** Refactoring is core and transport only;
`packages/blob` is neither. This sits with B-10, which keeps `data`, `blob` and
`notify` deferred.
