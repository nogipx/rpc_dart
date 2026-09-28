---
round: 478
verdict: FIXED
packages: [rpc_blob, rpc_blob_sqlite, rpc_blob_webdav, rpc_blob_minio]
lens: RPC-25
bench: none — the matrix is four implementations read against the tree, then pinned by one test per adapter
commit: yes
---

# Round 478 — one contract for a conditional delete

## Target

B-33, reachable for the first time: its decision says *"measure the four-row
matrix FIRST … then write the answer onto `IBlobRepository.deleteBlob`, then one
test per adapter"*, and it needed minio, which round 477 got running.

## Hypothesis

The lead says two adapters disagree. Round 471 recorded a matrix saying four
answers. Both were written before round 416, so neither is trustworthy — read all
four against today's tree first.

## Before

**Round 471's matrix was wrong, and it was my own.** It reported `in_memory`
throwing `StateError` and `webdav` throwing `StateError` on a mismatch. Both came
from the LEAD's prose, not from the code: that round read `minio` and `sqlite`
with a grep and took the other two on trust. Round 416 had converted them.

Read properly, all four:

```
blob MISSING, expectedVersion != null
  in_memory   throws ABORTED
  sqlite      throws ABORTED
  webdav      returns false
  minio       returns false

blob EXISTS at another version
  all four    throws ABORTED          <- already unified, by round 416
```

So **one axis was already one contract** and only the missing case diverged,
2-2 — a much smaller finding than the lead, and a different one.

## The answer, and why this one

`false` for a missing blob.

- It is what the contract sentence already said: *"returns `true` when something
  was removed"*. Nothing was removed.
- It cannot break a working caller. Nothing starts throwing that did not throw
  before; two adapters stop throwing. The alternative — ABORTED everywhere —
  would add a new throw to two published packages for a case that today returns
  quietly.
- It keeps a repeated delete idempotent for a caller that lost its response.

The mismatch case stays ABORTED, which needed no decision: round 416 established
that a `StateError` reaches a remote caller as INTERNAL with the version numbers
stripped, and all four already agree.

## Mechanism

```
in_memory   drop the throw on a missing blob; align the mismatch message
sqlite      read the version FIRST, in the same transaction
webdav      unchanged — already correct
minio       unchanged — already correct
```

**sqlite is the only non-trivial one.** A conditional `DELETE … AND version = ?`
reports `changes() == 0` for BOTH "gone" and "there at another version", and the
two now have different answers, so `changes()` cannot serve. The version is read
first inside the same transaction.

The interface now states both outcomes and why, with the measured before-state.

## After

Four adapters, one contract, each pinned in its own suite — which is the only way
to test them, since webdav needs a server and minio a live S3:

```
rpc_blob          +33   new file, witness + 3 guards
rpc_blob_sqlite   +38   the missing case added
rpc_blob_webdav   +13   both outcomes pinned
rpc_blob_minio    +24   both outcomes pinned, against live minio
```

## Canary

The witness is its own: before the change `in_memory` threw where the test now
expects `false`, and `sqlite`'s new case threw too. Both were red on the
unmodified adapters and are green after.

The guards are what stop the obvious wrong fix: a matching `expectedVersion`
still deletes (so "returns false" is not satisfied by deleting nothing), the
blob survives a refused delete, and an unconditional delete of a missing blob is
still `false`.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS over 15 packages. `rpc_blob_minio` run
separately against the container round 477 started.

## Not fixed

**`IDataStorageAdapter` and `INotifyRepository`**, which the lead names as having
the same structure and three implementations each. Not looked at — B-33's
decision is about the blob adapters, and widening it would be the scope creep
L-12 warns about. Worth its own lead if anyone wants it.

## Links

- RPC-25 — four implementations of one duty; and the round-471 correction is the
  lens's own warning, that a matrix read off a lead is not a matrix
- L-13 / rule one — the lead's prose AND my own record were both pre-416. The
  code is the only source that ages with the code
- Round 416 — which had already unified the mismatch axis without anyone noticing
- B-33, round 477 (got minio running), round 471 (the matrix that was wrong)
