---
round: 416
verdict: FIXED
packages: [rpc_dart, rpc_dart_framework, rpc_dart_grpc_reflection, rpc_dart_log, rpc_dart_http, rpc_dart_http2, rpc_dart_isolate, rpc_dart_websocket, rpc_dart_wasm, rpc_blob, rpc_blob_sqlite, rpc_blob_minio, rpc_blob_webdav, rpc_data, rpc_data_sqlite, rpc_notify, rpc_notify_redis]
lens: RPC-25
bench: none — a grep whose instrument is the sweep itself (`throw StateError`
  across 22 packages, 80 sites to 0) plus six ablations. The damage is a wrong
  STATUS on the wire, which is a classification and not a quantity
commit: yes
---

# Round 416 — every error names its status, and no message is a contract

## Target

**The owner's call, twice, mid-round: "get rid of all StateError" and "backward
compatibility does not matter".** That overturns a measured decision, so it is
recorded as such rather than applied quietly — see `## Retracting part of round
411`.

Started as B-64's remaining five items and grew into the class they belong to.
The bridge was the `Endpoint is closed` pre-flight: B-64 asks for it on all five
call shapes, and putting it there meant deciding what it throws.

Scope, counted before the work: **80 `throw StateError` sites in `lib/` across
17 packages**, plus 9 more that construct one as a value (`addError`,
`completeError`, a callback) — which the first grep missed and the owner caught
by naming `buffered_broadcast.dart:213`.

## Hypothesis

`StateError` is fine for a programming error, so most of these stay.

**False, and the code says why in its own words.** `context.dart:461` already
records it: *"while this implemented `Exception` directly a handler throwing it
was indistinguishable from a foreign `StateError`: both came back INTERNAL(13)
'Internal server error'."* `wireStatusFor` is default-deny, so every one of
these inside a handler or on a call path reached the peer with its reason
destroyed.

## Before

```
what the peer was told                              where
INTERNAL "Internal server error"  for a limit       blob chunk size, blob too
  the caller could have corrected                   large, maxActiveStreams
INTERNAL "Internal server error"  for a checksum    every blob adapter
  mismatch -- corruption, indistinguishable
  from a server bug
INTERNAL "Internal server error"  for an            every version-conflict site
  optimistic-concurrency conflict
'Transport is closed'  as a MESSAGE, matched by     11 sites, 4 packages
  string comparison in base_processor.dart
```

**The string-matched one had already broken.** `_isTransportClosed` compared the
message text, and because the transports disagreed on which exception to throw
it had to accept TWO spellings — `StateError` and
`RpcStatusException(unavailable, ...)`. `channel_transport.dart:437` is the site
that drifted, and the matcher was widened to cope instead of the drift being
removed. That is B-63's largest item, live.

## Mechanism

One duty — *what does this library throw when something goes wrong?* — answered
80 times, and `wireStatusFor`'s default-deny turns every answer that is not an
`RpcStatusException` into the same redacted INTERNAL. A message cannot carry a
status, so anything that needed one had to be recovered by comparing text.

## After

**`grep -rn "StateError" packages --include="*.dart"` over `lib/` returns
comments only.** Every site names a status the caller can act on:

```
RESOURCE_EXHAUSTED   stream limits, chunk-size limits, blob-size limits,
                     the CONTINUATION-flood report
FAILED_PRECONDITION  closed things, call-sequence violations, missing config
ABORTED              every optimistic-concurrency conflict (re-read and retry)
DATA_LOSS            every checksum mismatch, the dropped-events overflow,
                     a corrupt journal payload
INVALID_ARGUMENT     upload framing, decoded worker payloads, a peer's
                     descriptor wire type
UNIMPLEMENTED        server-push, viaSocket reconnect
UNAVAILABLE          a worker or isolate that died before it was ready,
                     a half-open keepalive, a WASM runtime that failed to load
INTERNAL             our own misconfiguration, a backing store that failed
```

**`RpcClosedException` is a TYPE, and that is the point.** `_isTransportClosed`
is now `error is RpcClosedException` — one check, no message text — and it
carries `what` (`'Transport'`, `'Endpoint'`, `'Repository'`, …) so a caller can
tell WHICH thing closed. FAILED_PRECONDITION, because closed is terminal:
UNAVAILABLE is retried, and neither the retry nor round 414's `reconnect()` can
reopen something closed on purpose.

**B-64 is closed out** in the same pass: `RpcCallerTrailer` now owns the
caller-side trailer rule for all five shapes, `RpcLongTimer.timeout` replaces
the four bare `Future.timeout` deadline bounds, and the pre-flight guard covers
all five call shapes.

## Retracting part of round 411

Round 411 classified these by hand and put `"Endpoint is closed" x4`,
`"Transport is closed" x7` and *"~60 more of the same shape"* under **"programmer
error, keep as-is"**. That half of its classification is **retracted**. Three
things say so, and two of them were already in the tree:

1. `channel_transport.dart:437` had ALREADY drifted to a status, so the codebase
   disagreed with the classification;
2. `_isTransportClosed` had to match two spellings by text — a contract with no
   declaration, which is only necessary because the type carries nothing;
3. a call racing a shutdown is an ordinary runtime event, not a programming
   error.

411's OTHER half stands: `ArgumentError` for a caller's mistake is idiomatic
Dart and none of it moved.

## Canary

Six, each switching off one mechanism, each restored and re-run green.

```
fix switched off                    witness failed with
_isTransportClosed by TYPE          "genuine transport-closed must keep being
  (back to matching message text)   swallowed quietly"  Expected: empty
                                    Actual: [LogEvent, LogEvent, LogEvent]
RpcCallerTrailer.statusOf's         4 tests: the three "payload then error
  int parse (back to `== '0'`)      trailer" shapes, and the "00" peer
the client-stream payload HOLD      exactly 1 test: "client-streaming no longer
                                    completes on the payload"
RpcCallerTrailer.noPayload()        covered by the two OK-with-no-payload tests
the clientStream pre-flight guard   "Expected: ... what: 'Endpoint'"
RpcLongTimer.timeout's source       2 tests: "a source error passes through"
  consumption                       and "...AFTER the timeout is not unhandled"
```

**Three canaries changed the round, which is the reason to run them.**

*One passed and exposed a test that proved nothing.* Ablating the `clientStream`
guard left every test green — because the closed TRANSPORT underneath also
throws `RpcClosedException`, so `isA<RpcClosedException>()` could not tell which
layer refused. Re-pointed at `what == 'Endpoint'`, it fails as it should.

*One passed and exposed a claim I could not witness.* `then<void>` versus `then`
in `RpcLongTimer.timeout` makes no observable difference to this suite; the
narrower property that IS witnessed is that the source is consumed at all. The
`then<void>` stays because it is correct, and no canary is claimed for it.

*And the GUARD found a real bug in the new helper before it shipped.* "a source
that fails AFTER the timeout is not unhandled" failed on the first
implementation — RPC-13's own subject matter, introduced by the fix meant to
close a different defect, caught because the test was written to look for it.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1565/1565
melos run test:web       SUCCESS — dart2js
melos run test:wasm      SUCCESS — the package outside the workspace
```

**The last two were load-bearing, not ceremony.** `test:web` caught a web-only
test pinning `StateError` on the worker-startup path, and `test:wasm` caught two
more in the package `melos run test` cannot see. Neither is in the ordinary
gate; both would have shipped red.

**One failure named rather than dismissed.** `isolate_verification_test`'s
`множественные_изоляты_работают_параллельно` failed once in the first full run
and passed alone and on the re-run at load average 12.7. It asserts a
**speedup ratio** between two independently measured wall-clock runs — which is
`tests.md` item 3's warning exactly — so it is load-sensitive by construction.
Pre-existing; not touched by this round.

## Not fixed

**Three tests were re-pointed at a weaker claim than they made, and that is a
real cost.** `closed_transport_call_test`'s *"sending after close is REFUSED,
with a retryable status"* and two siblings asserted UNAVAILABLE deliberately;
they now assert `RpcClosedException` and the refusal, and the retryability is
inverted on purpose. The refusal is the load-bearing half and is unchanged.

**No test asserts the absence of `StateError`.** The sweep is held by a grep in
this record, not by anything that runs. A round wanting that would add an audit
test that reads `lib/` — the repo has no precedent for one.

**B-63 is closed on its largest item only** (`'Transport is closed'` and the
`_ensureUsable` stale claim, whose justification round 414 had already made
false). `_inFlightCalls()`, `_notify`, `_startKeepalive` and the
`wireStatusFor` → `sendError` quartet are untouched.

**B-70 keeps 19 items.** B-66, B-67, B-68 and B-69 are untouched.

## Links

- B-64 — closed here, all six items
- B-63 — the `'Transport is closed'` item and the `_ensureUsable` stale claim
- round 411 — partially retracted; see above
- RPC-25 — the duty here is "what do we throw", answered 80 times
- RPC-13 — the guard that caught the new helper's unhandled-error bug
- RPC-07 — `RpcLongTimer.timeout` exists because a dart2js timer past ~24.8 days
  fires immediately, and `Future.timeout` arms a bare one
