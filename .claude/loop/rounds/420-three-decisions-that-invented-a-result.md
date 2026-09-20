---
round: 420
verdict: FIXED
packages: [rpc_dart, rpc_blob]
lens: RPC-25
bench: none — three decided leads, each a place where the code answered a
  question it had not been asked; the evidence is three ablations against named
  witnesses
commit: yes
---

# Round 420 — three decisions that invented a result

## Target

**B-40, B-36 and B-46** — three owner decisions already written down and never
carried out. `loop.py status` lists those first for a reason: a decision that
sits unexecuted is the loop holding an answer it asked for.

They share a shape worth naming: in each, the code SUBSTITUTED a result for one
it did not have.

## Hypothesis

Three small edits: split on the last dot, call the other resolver, add a guard.

Held for two. B-40's edit was small and in the WRONG PLACE — see below.

## Before

Each site answered a question it had not been asked:

```
                asked                        answered
B-40  key myapp.v1.UserService.Get   '/UnknownService/UnknownMethod'
        (4 parts on split('.'),      -- a diagnostic naming the wrong method
         the check wanted 2)
B-36  a probe nobody listened to     resolve(success: true) -> breaker CLOSED
        for probeAbandonTimeout      -- a recovery nothing observed
B-46  putBytes(id: '')               id=18df18eedb93057e
                                     -- "not stored" to a content-addressed
                                        caller, bytes orphaned
```

## Mechanism

**B-40: the two halves of one round trip disagreed about what a name may
contain.** `parseRpcMethodPath` admits a dotted service name — its token
pattern is `[A-Za-z0-9_.-]+`, and `myapp.v1.UserService` is the ordinary
protobuf spelling. The formatter split on EVERY dot and demanded exactly two
parts, so that key produced four and fell through to the unknown path.

**B-36: an unobserved probe is not evidence of recovery.** The abandon timer
called `resolve(success: true)`, which records a success and CLOSES the breaker
— on a result nobody observed. `resolveInconclusive()` already existed, three
lines up, doing exactly the right thing for the cancel path.

**B-46: `null` already means "generate one".** With null present, an empty
string is not a second way to ask — it is a caller whose id-building produced
nothing. For a content-addressed caller the substituted id reads as "not
stored" while the bytes sit orphaned under a name nothing references.

## After

`rpcMethodPathFromKey` splits on the LAST dot and lives in `metadata.dart`
**beside `parseRpcMethodPath`**; the abandon timer calls `resolveInconclusive`;
both implementations of `IBlobClient.putBytes` refuse an empty id with
INVALID_ARGUMENT.

### The first witness I wrote was a tautology

B-40's formatter was private on a mixin that RPC-24 hides from the public
surface, so the test reimplemented the rule and checked itself — it would have
passed with the production code reverted, which the canary is exactly for.

The fix was to move the formatter next to the parser rather than to write a
cleverer test. That is better anyway and is the round's real finding: **an
inverse pair that cannot be read together is an inverse pair that drifts.** The
test now asserts the PROPERTY — the formatter rebuilds everything the parser
admits — against both real functions.

### The test B-36 predicted would move, moved

`audit_circuit_breaker_abandoned_probe_test` asserted `closed` under the reason
*"abandon safety timer must release a wedged half-open probe"*. The reason names
the RELEASE and the assertion observed it through the CLOSE; those came apart
the moment the close became wrong, and `closed` is also what a fabricated
success produces, so it could not tell the two apart. It now asserts `halfOpen`
**plus a following call that is admitted** — the gate itself, which is the half
`closed` only implied.

## Canary

```
fix switched off                   witness failed with
rpcMethodPathFromKey's last-dot    3 of 4 tests, incl. the property one
  split (back to split('.'))
the abandon timer's                "abandon safety timer must release a wedged
  resolveInconclusive                half-open probe"
the empty-id refusal               "an empty id is REFUSED, not silently
                                   generated" -- and BOTH controls stayed
                                   green, so it is not "refuse everything
                                   without an id"
```

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**B-40's formatter is still not driven end to end.** It is reached only when
both retained messages are null and `methodKey` is set — the deadline/abort
diagnostic path — and the witness calls the function directly. The happy path
never reaches it, which is why a two-hundred-round-old defect was invisible.

**The two `putBytes` implementations throw DIFFERENTLY.** `BlobServiceClient`'s
is `async` so its refusal is asynchronous; `BlobRepositoryClient`'s is not, so
its refusal is synchronous. Every caller awaits, so both are caught the same
way, but a caller that does not await sees one and not the other. Not unified
here; noted rather than left to be discovered.

**B-46's adjacent check was not done.** The lead asks to look for the same shape
in `rpc_blob_sqlite` and `rpc_blob_webdav`. Those are storage ADAPTERS, and the
empty-id substitution they perform (`first.blobId.isEmpty ? null : ...`) is the
deliberate wire encoding this fix deliberately did not touch — so the shape is
not there. The adapters' own `deleteBlob` disagreement is B-33 and still open.

## Links

- B-40, B-36, B-46 — all three closed here
- RPC-25 — an inverse PAIR is two implementations of one rule
- B-33 — the adapter disagreement B-46 points at, still open and still needing
  minio and postgres to measure honestly
