---
round: 471
verdict: INCONCLUSIVE
packages: [rpc_blob_sqlite]
lens: RPC-11
bench: none — the instrument is each excluded suite's own exit status, and two of the five could not be started
commit: yes
---

# Round 471 — the other suite nobody runs

## Target

Round 470 found a never-run suite red on a `StateError` assertion that round 416
obsoleted. That is a CLASS, not an instance: 416 converted ~80 sites across 17
packages, every suite the gate RUNS was updated with it, and the suites the gate
EXCLUDES were not. This round asks how many.

Also in scope: B-33's own first step, which the owner asked for before any fix —
the four-row matrix for `deleteBlob` on a missing blob.

## Hypothesis

If the wasm suite went stale for being outside the gate, the other excluded
suites did too, and for the same reason.

## Before

The exclusion list, read as a population for the first time:

```
config.md, excluded from test:unit    *_postgres, *_minio, the SQLCipher test
CLAUDE.md, excluded from every test*  rpc_dart_generator (build_test)
outside the workspace                 rpc_dart_wasm (its own scripts)
```

Of those, one had been run — by round 470, and it was red.

## What was measured

The one excluded suite reachable without a service:

```
melos exec --scope=rpc_blob_sqlite -- fvm dart test    +30 -7
```

```
Expected: throws <Instance of 'StateError'>
  Actual: <Closure: () => Future<PutBlobResponse>>
   Which: threw RpcClosedException:<RpcStatusException(9): Adapter is closed>
```

Same shape as round 470's. Two instances, two packages, one cause.

**And the exclusion reason is only partly true.** `config.md` excludes the sqlite
packages because *"the SQLCipher test needs a cipher-enabled native lib"* — the
suite runs, and these seven failures are not that test. The exclusion is broader
than its stated reason, which is why nobody saw the suite was red.

## B-33's matrix, derived by reading all four adapters

The owner asked for this before any fix, and the lead had compared two of four.
Input: the blob is MISSING and `expectedVersion != null`.

```
in_memory   throws StateError('Expected version N ... but blob is missing.')
webdav      returns false
minio (S3)  returns false          -- headBlob null, returns before the check
sqlite      throws RpcStatusException(aborted, '... no rows deleted.')
```

**Four adapters, two answers, and the two that throw throw DIFFERENT TYPES.** The
lead's claim that *"for a mismatch on an EXISTING blob both throw `StateError`"*
is true of the two it read and false across four: minio and sqlite both raise
`RpcStatusException(aborted)` there.

So round 416's rule settles half of it without a judgement call —
`RpcStatusException(aborted)` is right and `StateError` is wrong, because
`wireStatusFor` redacts the latter to INTERNAL. What it does not settle is the
missing-blob case, where the interface's own doc (*"returns `true` when something
was removed"*) points at `false` and two adapters already agree with it.

## Mechanism

None. No code changed.

## After

Unchanged.

## Canary

None — nothing was fixed.

## Gate

Not re-run: no source changed. The last full gate, in round 470, was green
(analyze, format:check, license:check, test:unit over 14 packages, test:wasm +44,
test:wasm:device +24 ~2).

## Why INCONCLUSIVE rather than a fix

**The class is not counted, and four of its members cannot be reached here.**
`rpc_blob_minio`, `rpc_data_postgres`, `rpc_notify_postgres` and
`rpc_notify_redis` need docker services. Fixing the two suites I can see while
four remain unmeasured is exactly the under-delivery L-12 exists to prevent — it
would report a subset as the job.

**And the service blocker was tried, not assumed.** Docker is running here, and
the minio test file documents its own command; the REGISTRY refuses:

```
docker run -d --rm -p 9010:9000 quay.io/minio/minio server /data
  -> unauthorized: access to the requested resource is not authorized
docker pull minio/minio:latest
  -> pull access denied ... may require 'docker login'
```

Registry credentials, then — not a missing daemon, not the allowlist. Recorded in
B-92 the way round 470 wishes B-38 had recorded its own: a blocker is a claim and
ages like one.

**And one failure may not be staleness.** Round 470's was: the type changed, the
timing assertion the test existed for still held. Here a checksum-mismatch test
reports `Adapter is closed`, which is a different sentence, and rewriting the
assertion would bury whatever produced it. That question has to be answered
first, and answering it is a round.

Filed as **B-92**, with the count, the trap and the three measurable questions.

B-33's matrix is recorded in the lead so its step one is not re-derived. The fix
it leads to — one answer written onto `IBlobRepository.deleteBlob` and four
adapters brought to it — is a behaviour change across four published packages and
was not attempted here.

## Not fixed

The seven assertions, deliberately. See above.

The four service-dependent suites, for want of the services.

**B-33's unification**, whose step one is now done. Sized: the interface doc, two
adapters changed on the missing-blob axis (in_memory, sqlite), two on the
mismatch axis (in_memory, webdav), and one test per adapter — with two of the
four suites unrunnable here, which is the same wall as above.

## Links

- RPC-11 — a package outside the gate; round 470 is the first instance and this
  is the second, which is what makes it a class
- L-12 — count the class before fixing any of it; the count is what this round
  delivers and why it stops short
- Round 416 — where the type changed; round 470 — the first stale suite
- B-92 (filed), B-33 (step one done)
