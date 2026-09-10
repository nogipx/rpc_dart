---
round: 310
verdict: FIXED
packages: [rpc_dart_isolate, rpc_dart_websocket]
lens: RPC-25
bench: none
commit: yes
---

# Round 310 — the lens applied after all

## Target

The two packages the mandate's boundary and abstraction clauses had not reached
as WORK rather than as an audit: `rpc_dart_isolate` and `rpc_dart_websocket`.

Round 309 closed isolate with "the lens does not apply". That claim is the
target of this round, because it was reached by argument rather than by running
the detector — and it was wrong.

## Hypothesis

If RPC-25's step 1 is actually run on isolate — grep for a FIELD every sibling
declares — it returns something. If it returns nothing, 309 was right.

## Before

Step 1, run rather than reasoned:

```
_IsolateMultiplexedChannel        _WebMultiplexedChannel
  _incomingCtl  broadcast(sync)     _incomingCtl  broadcast(sync)
  _messageSub                       _messageSub
  _closed                           _closed
  _onClose                          _onClose
```

Four fields, same names, same types, same constructor shape, and a `close()`
that is byte-identical between the two files. **They are the same
`IRpcMultiplexedChannel` lifecycle written twice.** 309 reasoned about the
MECHANISM — SendPort against Worker — and concluded no siblings; the mechanism
is a parameter of the shape, not the shape.

## Mechanism

Step 3 found two drifts, and the first is a live defect.

**1. A send failure kills the whole connection on web.**

```dart
// VM
} catch (error, stack) {
  // ... "this is one message's problem, and closing the channel here would
  //      make it the whole connection's, killing every other in-flight call
  //      over one bad payload."
  Error.throwWithStackTrace(ArgumentError('... cannot cross an isolate boundary'), stack);
}

// web
} catch (_) {
  await close();
}
```

The VM copy carries a comment explaining precisely why closing is wrong. The web
copy does the wrong thing anyway — and `catch (_)` drops the reason, so the
caller is told UNAVAILABLE for what is a non-cloneable payload on ONE stream.
Every other call on that worker dies with it.

This is the strongest form of the shape: not two copies that merely differ, but
one copy still carrying a defect its sibling was *explicitly fixed away from*,
with the explanation sitting in the other file where nobody comparing them
would look.

**2. Stream 0 is reserved on both, filtered on one.** The VM channel drops
`data`/`finish` frames on stream 0 (reserved for the init/ready/close handshake)
and deliberately does NOT drop `metadata`, because that is
`RpcChannelTransport`'s connection-level flow control. The web channel filtered
nothing, so a payload frame on the reserved stream reached the endpoint.

**The remedy here is alignment, not extraction.** The two compile on different
platforms and speak different wire formats; one shared class would be an
abstraction over nothing. RPC-25 is about ending the divergence, and merging is
only one of the two ways to do that.

**And the boundary half, on websocket.** Completing RPC-24's step 1 properly —
my earlier pass matched types and missed top-level FUNCTIONS — showed
`grpcStatusFromWebSocketCloseCode` public, used by this package's `lib/` and its
own tests and nothing else. Round 307 hid exactly this shape in http2
(`grpcStatusFromHttpStatus`), and justified keeping the websocket one by saying
it "mirrors" the http2 function — a mirror that same round had just removed. The
two packages now agree: a close code reaches a caller already turned into an
`RpcStatusException`, so a user never calls the mapper.

## After

```
rpc_dart_isolate     2 drifts closed, 0 remaining between the channel siblings
rpc_dart_websocket   public surface 5 -> 4
```

## Canary

**The isolate drift has a real witness, and it is not the suite.** Both copies
compile and both suites pass — that is why the defect survived. The witness is
the sibling comparison itself: `send()` in the two files now agrees on what a
failure means, and the disagreement is what a reviewer can see in one diff.

The websocket narrowing was MEASURED, as RPC-24 requires: 10 errors, in 2 test
files, 0 in `lib/`, 0 in any other package — the same machinery-and-tests split
http2 gave, which is what makes it the same call.

Workspace suite: 14 packages, 0 failures.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1310/1310.

## Not fixed

The isolate web channel is not covered by `melos run test:unit` — the package's
web variant needs a browser, and `test:wasm` is a different package. The two
fixes here are therefore analyzer-verified and sibling-verified but not
exercised on their own platform. That is a pre-existing gap in the gate rather
than something this round introduced, and it is the honest limit on the claim.

B-30 remains open and remains the owner's call.

## Links

RPC-25 (`applied:` gains 310). Round 309's "does not apply" is **corrected in
place**, and the lens gains the rule that produced the correction: *different
mechanism is not different abstraction*, and "the lens does not apply" is a
claim that needs the grep, not an argument.

RPC-24 for the websocket half, and for the inconsistency round 307 created by
hiding one of a pair.
