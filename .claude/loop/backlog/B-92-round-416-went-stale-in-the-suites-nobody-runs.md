---
status: open
round: 471
commit: 8a32b446
paths: [packages/blob/rpc_blob_sqlite/test/**, packages/blob/rpc_blob_minio/test/**, packages/data/rpc_data_postgres/test/**, packages/notify/rpc_notify_postgres/test/**, packages/notify/rpc_notify_redis/test/**]
probe: none — the instrument is each excluded suite's own exit status
reason: bench — two instances found, the class is "every suite the gate excludes"; the count has to come before any fix
---

# B-92 — round 416 went stale in the suites nobody runs

## The class, and how it was found

Round 470 ran `melos run test:wasm:device` on Android for the first time ever and
it was RED on a test expecting a `StateError` the library stopped throwing in
round 416. Round 471 then checked the OTHER excluded suite it could reach:

```
melos exec --scope=rpc_blob_sqlite -- fvm dart test    +30 -7
```

Seven failures, same shape:

```
Expected: throws <Instance of 'StateError'>
  Actual: <Closure: () => Future<PutBlobResponse>>
   Which: threw RpcClosedException:<RpcStatusException(9): Adapter is closed>
```

**Two instances, two packages, one cause.** Round 416 replaced ~80 `StateError`
sites across 17 packages with typed status exceptions — its finding was that
`wireStatusFor` is default-deny, so a `StateError` is redacted to INTERNAL and the
caller loses the reason. Every suite the ordinary gate RUNS was updated with it.
The suites the gate EXCLUDES were not, and nothing has asked them since.

## Why this is a lead and not a fix

**The count is unknown and it comes first** (L-12). The excluded set is larger
than the two found:

```
config.md excludes from test:unit    *_postgres, *_minio, the SQLCipher test
CLAUDE.md excludes from every test*  rpc_dart_generator (build_test)
outside the workspace               rpc_dart_wasm (its own scripts)
```

So the population is at least: `rpc_blob_sqlite`, `rpc_blob_minio`,
`rpc_data_postgres`, `rpc_notify_postgres`, `rpc_notify_redis`,
`rpc_dart_generator`, and whatever else a sweep turns up. Two have been run; the
rest have not, and two of them need services this session does not have.

**And `rpc_blob_sqlite`'s exclusion reason is only partly true.** `config.md` says
the sqlite packages are excluded because *"the SQLCipher test needs a
cipher-enabled native lib"* — but the suite runs, and the seven failures are not
that test. So the exclusion is broader than its stated reason, which is why
nobody noticed the suite was red.

## The measurable questions

1. **How many suites, and how many stale assertions in each?** Run every suite
   that can run without a service. `rpc_blob_minio`, `rpc_data_postgres`,
   `rpc_notify_postgres` and `rpc_notify_redis` need docker services up first.
2. **Is every failure staleness, or is any of them a real defect?** The wasm one
   was pure staleness (the timing assertion the test existed for still held). The
   sqlite ones say `Adapter is closed` on a CHECKSUM test, which is not obviously
   the same thing — a cascade from an earlier failure, or a real path change.
3. **Why is `rpc_blob_sqlite` excluded at all?** If only one test needs the
   cipher lib, that test can be skipped and the rest of the suite joined to the
   gate — which is what would stop this recurring.

## What was tried for the services, so it is not retried blindly

Docker IS running here (two unrelated containers up), and the minio test file
documents its own command. The registry is what refuses:

```
docker run -d --rm -p 9010:9000 quay.io/minio/minio server /data
  -> unauthorized: access to the requested resource is not authorized
docker pull minio/minio:latest
  -> pull access denied ... may require 'docker login'
```

So the blocker is registry credentials, not a missing daemon and not the
allowlist. Someone logged in to a registry can run the documented command and the
four service-dependent suites become reachable in one go.

**Recorded this way on purpose**: B-38 carried a blocker for thirteen rounds that
named the wrong obstacle, and round 470 found it false. A blocker is a claim and
ages like one.

## The trap

Do not fix the seven assertions one at a time until question 2 is answered.
Round 470's was a stale TYPE and the behaviour under test was fine; a failure
reading `Adapter is closed` where a checksum was expected may be reporting
something real, and rewriting the assertion would bury it.

## Owner decision

—
