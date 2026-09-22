---
round: 425
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-95 — new
commit: yes
---

# Round 425 — the cancel path the table had no column for

## Target

**B-56's extraction**, which round 424 deliberately left and which the owner
took as a decision. Carried out for the BRIDGE half of the class, and the scope
was decided before the fix, not after it.

B-56's sweep counts nine sites of one mechanic. Reading them apart gives two
mechanics that its single table conflates:

```
  bridge   mirror a source through a controller the library owns
           6 _bridgeCallerResponses    7 RpcCallScope.track
           9 circuit breaker _wrapStream
           2 ServerStreamResponder's relay
           + _pumpBidirectionalResponses (responder_pipeline.dart:1713),
             which the nine-site sweep does not list at all
  pump     drive a source into a call, pausing the subscription per send
           1 ClientStreamCaller.call   3 the bidi bridge's request half
           4 requestSink               5 responseSink
```

Six bridges, not five sites; four pumps. "pause per send" and "forward the
consumer's pause" are different mechanisms sharing a column heading.

This round takes the six bridges. The four pumps are a second helper and are
**not** in it — see `## Not fixed`.

## Hypothesis

A bridge has TWO cancel paths — the consumer's and the owner's — and B-56's
table has one column. Round 424 fixed the owner half at two sites. If the
columns are really one, the consumer half is right everywhere; if not, the
extraction is being measured against a suite that is not as green as the
decision assumed (L-13).

It was not.

## Before

`StreamController` AWAITS whatever `onCancel` returns. Two of the six returned
the source's cancel Future:

```dart
// RpcCallScope.track
onCancel: () => sub.cancel().catchError(_cancelFailed),
// the circuit breaker's _wrapStream
onCancel: () async { resolveInconclusive(); await sub.cancel(); },
```

Consumer `cancel()` over a source that parks, 3000 ms cap:

```
1 track(parked)               HUNG (>3000ms)
2 breaker(parked)             HUNG (>3000ms)
3 CONTROL unawaited(parked)   6ms
4 CONTROL track(prompt)       7ms
5 CONTROL site 6 bridge       7ms
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/bridge_cancel_paths.dart`
(P-95).

Arm 5 is the premise check L-13 asks for: site 6, the copy B-56 designates as
the extraction source, reads 7 ms on a REAL server-stream call whose caller-side
`async*` is parked in `await for (responses)` — a server stream at idle. The
decision's source of truth is sound; the sentence about the other copies was
not.

## Mechanism

`track` is public API a handler calls on a stream the handler supplied — the
whole ownership criterion of this class. A consumer doing `.first`, `.take(n)`
or an ordinary `cancel()` on a tracked parked generator waits for a generator
that never unwinds, with nothing to bound it: `disposerTimeout` bounds the
disposer path only, which is the half 424 fixed.

The breaker's copy is the same shape one file over, and its source is the
caller-side `async*` above.

## After

Same probe, same arms: `1 → 8ms`, `2 → 5ms`, controls unchanged.

The fix is the extraction. `StreamBridge` (`src/core/stream_bridge.dart`, hidden
from the public barrel) owns the four clauses — forward pause/resume, close on
the source's done, and BOTH cancel paths, `onCancel` and `cancelSource()`/
`close()`, neither awaited. All six bridges now go through it:

```
lib, 8 files changed      -158 / +62      plus 119 lines of helper
five ad-hoc controllers   collapsed into one, with two ad-hoc guards
                          (`torn`, the `_handlerSubscription` null dance)
                          subsumed by the helper nulling its own handle
```

## Canary

```
fix switched off in StreamBridge     witness failed with
onCancel returns the source cancel   "cancel() never completed within 3000ms:
                                      onCancel returned the source cancel, so a
                                      handler doing .first on a tracked
                                      generator waits for a generator that
                                      never unwinds"   -- track
                                     "...the breaker awaited the source cancel
                                      in onCancel, and the source is the
                                      caller-side `async*` parked in `await for
                                      (responses)`"    -- the circuit breaker
onPause/onResume not forwarded       "without pause forwarding the bridge
                                      buffers without bound" AND round 424's
                                      own `track forwards backpressure` witness
cancelSource() made a no-op          "the source was never cancelled at all:
                                      not awaiting it must not mean leaking
                                      every subscription the bridge holds"
```

**ONE ablation, two sites red.** That is the property the extraction buys and
the only thing here that a per-file fix could not have shown: before this round
the same ablation had to be made twice, in two files, to break two witnesses.
The three GUARDs stayed green under the first ablation, so the witnesses isolate
the consumer-cancel clause and not the bridge in general.

The third canary needed a surgical form — inverting the null check does not
compile under flow analysis — so it is `if (1 > 0) return;` at the top of
`cancelSource`.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1589/1589
melos run test:web       SUCCESS -- 12 dart2js suites, 0 failures
rpc_dart alone           +1639 ~1, all passed
```

## Not fixed

**The four PUMP sites are not converted, and this round does not claim them.**
`ClientStreamCaller.call`, the bidi bridge's request half, `requestSink` and
`responseSink` share a different mechanism — pause the subscription for the
duration of each send — and a helper for them is a different signature with
different hooks (half-close, abort-the-peer, stop-on-done). 4 and 5 are near
twins and are the obvious pair to start from. No defect is known in any of the
four; B-56's read of them stands and this round did not re-take it.

**Sites 1-6's other clauses were not re-measured.** Arm 5 re-measures ONE
thing — site 6's consumer-cancel — because that is the clause this round is
about and the one the extraction copies outward. The rest of B-56's table is
still a READ.

**No witness asserts that the OWNER-teardown path still cancels `track`'s
source.** Canary 3 ablates `cancelSource()`, which both paths now call, and the
guard that went red goes through the consumer path; round 424's scope-close
witness measures the TIME and stays green on a no-op cancel. One implementation
covered through one of its two callers — which is the extraction's own argument
and is stated rather than implied.

**`RpcCallScope.listen` (site 8) is not a bridge** and is unchanged: it hands
back the raw subscription and registers a disposer, with no controller between.

**`_stateBoundStream` (responder_pipeline.dart:1984) also returns its cancel
from `onCancel`** and is deliberately out: its source is
`transport.getMessagesForStream`, which the library owns. Recorded so the next
sweep does not re-derive it — the comment four lines above it notes a transport
is a public extension point, which is the argument for revisiting it, and that
belongs with B-56's untouched transport half rather than here.

## Links

- B-56 — the extraction, carried out for the bridge half; the pump half stays
- L-13 — an owner decision inherits the sentence it was taken on. The decision
  said every copy is correct as of 391 and that the refactor could be measured
  against a green suite; arm 5 confirmed the source copy and arms 1-2 refuted
  the sentence. Re-measuring cost one probe and found the round's defect
- L-16 — cancel UNAWAITED, third round running. Here the absence was in a
  parameter position nobody reads as a cancel: the RETURN of an `onCancel`
  callback
- RPC-25 — the copies did not drift by accident; they drifted in the one clause
  that is invisible unless the two paths are named apart
- L-12 — extended with its second half: a count is taken on an AXIS, and 415's
  axis put two cancel paths in one column, so 424 counted the class correctly
  and still fixed half of it
- P-95 — the bench
