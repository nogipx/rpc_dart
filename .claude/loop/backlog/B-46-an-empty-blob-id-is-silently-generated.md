---
status: decided by owner (round 415)
round: 366
commit: bb8548939524ee67a53dcc5339d15f772e3f032e
paths: [packages/blob/rpc_blob/lib/src/client/blob_repository_client.dart, packages/blob/rpc_blob/lib/src/adapters/in_memory_blob_repository.dart, packages/blob/rpc_blob_minio/lib/src/adapters/s3_blob_storage_adapter.dart]
probe: packages/blob/rpc_blob/.dart_tool/probes/probe_empty_id_substitution.dart
reason: owner decision — `packages/blob` is outside the scope the owner set for refactoring work (see B-33, B-10), so the substitution is filed rather than changed
---

# B-46 — an empty blob id is silently replaced by a generated one

`putBlob` hands the repository `id: first.blobId.isEmpty ? null : first.blobId`,
and every `writeBlob` opens with `request.id ?? _generateId()`. So a caller that
asks to store a blob **under the empty id** gets a random one instead, and
nothing says so:

```
CONTROL   asked=aabbccdd11223344  got=aabbccdd11223344
EMPTY-ID  asked=""                got=18df18eedb93057e  <<< substituted, no error
          stored under the generated id: true
```

At the WIRE level the convention is defensible and deliberate:
`BlobUploadChunk.blobId` is a non-nullable `String`, so empty has to mean
"you pick one". The defect is one layer up — **`putBytes` takes `String? id`,
where `null` already means "you pick one"**, so an empty string arriving there
is not a request to generate, it is a caller with a broken id. It is answered as
if it were the former.

## Why it matters more than it looks

For a CONTENT-ADDRESSED caller the returned id is not a detail, it is the whole
answer. rhyolite stores by hash and verifies every id it sent against the ids
the server acknowledges; a substitution reads to it as *"the server did not
store my blob"* while the bytes sit in the bucket under a name nothing
references — a silent loss and an orphan object in one.

## NOT the field defect it was found looking for

rhyolite's blob ids are keyed-HMAC hex and are never empty, and its wire codec
(`BlobChunk.fromJson`) reads an absent `blobId` as `null`, not `''`. So this
cannot be what makes their batches come back short. Recorded because the path is
one `''` away from it, and because the same substitution would hide a future
caller's bug rather than report it.

## The fix

`putBytes` refuses an empty non-null `id` — `null` keeps meaning "generate".
One line and a test; the wire-level empty→generate convention stays as is.
Worth checking the same shape in `rpc_blob_sqlite` and `rpc_blob_webdav`, which
were not looked at.

## Owner decision

**Taken: refuse it.** `putBytes(id: '')` throws `ArgumentError` rather than
generating.

The argument is that the API already has a way to ask for a generated id, and it
is `null`. With `null` present, an empty string is not a second way to ask — it
is a caller whose id-building produced nothing, being answered as though it had
made a request. For a content-addressed caller, which is what these packages
exist for, the substituted id reads as "not stored" while the bytes sit orphaned
under a name nothing references.

**The wire level does NOT change.** `BlobUploadChunk.blobId` is non-nullable, so
empty-means-generate is the only encoding available there and is deliberate. The
refusal belongs at `putBytes`, where `null` exists — not at the protocol, where
it does not.

In scope because B-10's deferral was narrowed to LOOKING; this defect is already
measured (`asked="" got=18df18eedb93057e`).

Check the same shape in `rpc_blob_sqlite` and `rpc_blob_webdav` while there —
they were never looked at, and a refusal in one implementation of an
interchangeable interface is B-33 all over again.
