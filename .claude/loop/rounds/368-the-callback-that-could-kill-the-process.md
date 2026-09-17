---
round: 368
verdict: FIXED
packages: [rpc_dart]
lens: RPC-13
bench: P-59 — new
commit: yes
---

# Round 368 — the callback that could kill the process

## Target

The owner asked, mid-round, for **full correctness of all four call shapes in
ordinary AND edge cases**. That is a parity question, so the instrument is
RPC-25's detector — ask the same question of all four siblings and treat the
divergence as the defect — and the shape that came out of it is RPC-13's, which
is why the frontmatter names RPC-13: its `breaks:` is *a process crash*, and that
is what was found.

Scope, counted before anything was touched (L-12): every `async` callback handed
to `Stream.listen` (plus one dropped `.then/.catchError` chain) inside
`packages/core/rpc_dart/lib/src/rpc/streams/` — **11 sites, 5 already carrying a
try/catch and 6 not**. All 11 are in scope; the 6 are the work.

## Hypothesis

The four shapes diverge on some edge case. Specifically: a callback that is
`async` has nothing awaiting it, so anything it throws reaches
`Zone.current.handleUncaughtError` — which for a server with no zone handler is
exit 255, the failure `_detached` in `responder_pipeline.dart` was written for
after two production replicas died of it.

## Before

Five edge cases, each asked identically of all four shapes. `observed` is how
many payloads reached the consumer, then the exception type that ended the call:

```
EC0 ordinary        unary  1 DONE | server  3 DONE | client  1 DONE | bidi  3 DONE
EC1 handler throws
    part-way        unary  0 Rpc  | server  2 Rpc  | client  0 Rpc  | bidi  2 Rpc
EC2 peer transport
    dies mid-call   unary  0 Rpc  | server 10 Rpc  | client  0 Rpc  | bidi  9 Rpc
EC3 consumer
    cancels                         server  6         (n/a)          bidi  6
EC4 call CANCELLED, producer pushes one more request
    bidi  requestSink          uncaught +1
    client call(Stream)        uncaught +0
CONTROL unguarded async listen callback   uncaught +1
```

`Rpc` is `RpcStatusException`. **EC0-EC3 are identical across all four shapes** —
a handler that fails part-way delivers its partial output AND an error (no silent
truncation), a dead transport is reported, a consumer that walks away is not
left hanging. Only EC4 diverged.

Probe: `packages/core/rpc_dart/.dart_tool/probe/shape_edge_matrix.dart` (P-59).

The two EC4 rows are each other's control, and they are the same job written
twice: the library driving a producer the application handed it.
`ClientStreamCaller.call(Stream)` wraps its send in `.catchError` and reports
**+0**; `BidirectionalStreamCaller.requestSink` does not and reports **+1**. The
CONTROL row is the instrument's own: a bare `listen((_) async { throw ... })`,
+1, so a 0 elsewhere means "nothing was thrown", not "nothing was watched".

## Mechanism

`CallProcessor.send` throws `RpcStatusException(14)` by design once the call is
no longer active — round 330's fix, so that a caller cannot be told a request
went out when it did not. `requestSink`'s listener awaited that throw inside an
`async` callback with nothing holding the future. A cancelled call whose producer
has not noticed yet — an ordinary shape, the sink is still open — therefore
raised into the zone.

The same one line covers the other five: each is an `async` callback whose body
can throw, and the most reachable is `UnaryResponder`'s own subscription, where
`handleMessage`'s error path answers the peer over a transport that is already
gone — which is exactly when a handler fails.

## After

Same probe, same run:

```
EC4  bidi requestSink   uncaught +1  ->  +0
     client call(Stream) uncaught +0  ->  +0
CONTROL                  uncaught +1  ->  +1   (instrument still live)
EC0-EC3                              unchanged, all four shapes
```

Six sites guarded, each with a try/catch that logs at `error` — the shape
`BidirectionalStreamResponder`'s `responseSink` listener already used, so the
mirror APIs now agree. `UnaryResponder`'s 90-line listener body became
`_onIncomingMessage`, so the guard has one place to sit instead of three.

## Canary

Two, one per witnessed site, each `rethrow;` added to the new catch — the exact
pre-fix behaviour, nothing else changed.

**`bidirectional/caller.dart`, requestSink:**

    Expected: empty
      Actual: [RpcStatusException:RpcStatusException(14): Request not sent:
               the call is no longer active]

**`unary/responder.dart`, the listener:**

    Expected: empty
      Actual: [RpcStatusException:RpcStatusException(14): Transport is closed]

Neither is a timeout. Each canary killed **only its own** witness; both GUARD
tests (requestSink still delivers `[a, b]` and half-closes; an ordinary unary
call still answers) passed on both sides, so the tests isolate the new defect
rather than the feature.

Witness: `test/streams/call_shapes_cannot_kill_the_process_test.dart`, 4 cases.

## Gate

All four green: `melos run analyze` (21 members + wasm, `No issues found!`),
`melos run test:unit --no-select` (rpc_dart **+1531 ~1**, rpc_dart_http2 +218,
rpc_dart_websocket +165), `melos run format:check`, `melos run license:check`
(1413/1413). In the changed package: `fvm dart analyze lib` clean,
`fvm dart test -j 8` **+1531 ~1**.

`format:check` was red once on the new test file only; formatted and re-run.

**`melos run test:web` is RED on one arm and it is not this round's.**
`rpc_dart_isolate`'s `-p chrome` smoke fails at `BrowserManager._start` — Chrome
never connects to the test channel — identically at `--timeout 3x` and `6x`, i.e.
before a line of Dart runs. Control: `rpc_dart_websocket`'s `-p chrome` smoke,
same Chrome, same locally-resolved core, **4 passed**. The node arm is green
inside melos; a bare `fvm dart test -p node` dies `ENETDOWN` on all 115 files
because only the repo's own script sets `NODE_OPTIONS=--dns-result-order=ipv4first`.
Filed as B-48; whether it pre-dates this round was not established.

## Not fixed

**Four of the six guarded sites have no witness**, and that is L-04's shape: a
guard against a crash is witnessed by an absence. They are
`bidirectional/caller.dart` `onDone`, `bidirectional/responder.dart` `onDone`,
`server/responder.dart` `onError` and `client/responder.dart`'s `.catchError`
chain. Each reaches the zone only if a collaborator that is internally guarded
today stops being so — which is precisely why the guard belongs at the callback
rather than in the collaborator. Counted and named rather than left implied.

**The five already-guarded sites were not touched.**

**`BidirectionalStreamCaller.requestSink` still has no back-pressure.** Its
listener does not pause, so a producer runs ahead of the transport without
bound — the unbounded queue `ClientStreamCaller.call()` fixed in its own
`requestSub.pause()` (measured there: 2000 messages, 32.8 MB pulled against a
1 MB window). The same sibling pair, the same drift, one axis over. Not this
round's subject and it needs its own bench; filed as B-49.

## Links

- RPC-13 — the lens; `applied:` gains 368, status `confirmed (round 368)`
- RPC-25 — supplied the detector (four siblings, one question); `applied:` gains 368
- P-59 — the edge-case matrix
- C-40 — the negative: EC0-EC3 agree across all four shapes
- B-48 — the isolate package's Chrome arm
- B-49 — requestSink has no back-pressure
- L-04 — a guard against an absence has no witness; four sites are in that state
- L-12 — the class was counted (11 sites, 6 unguarded) before anything was fixed
- Round 356 — RPC-13's last application, the CATCHING side of the same question
- `responder_pipeline.dart` `_detached` — the production incident this class killed two replicas with
