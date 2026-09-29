---
status: closed (round 487)
round: 487
commit: 7764b081
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
probe: P-126
reason: "closed — the witness was built and CONFIRMED it: 0 of 1 cancels observed and 0 of 1 disposers run after one extra frame"
---

# B-96 — a second metadata frame with a methodPath replaces a running call's context

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

For an existing stream `storeMetadata` clears the cache and `_cacheContext` builds a NEW context — new token, new `RpcCallScope`, new deadline timer — while the running handler keeps the old one; drain, deadline, client cancel and teardown then reach a token the handler does not hold, and the handler's own call scope is never closed.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart:817-819` routes every metadata-only frame
with a methodPath to `_handleMetadataMessage`, with no check that the stream is
already bound. There (`:944-947`):

```dart
state.setMethodKey(methodKey);
state.storeMetadata(message);          // _cachedContext = null
final context = _cacheContext(state, message);   // new token, scope, deadline
```

`responder_streams.dart:240-243` (`storeMetadata`) and `:51-62` (`armDeadline`
cancels the previous timer). For `_isPingMethodKey` the ping is answered again.

## Why it matters

Everything that stops a handler reads `state.cachedContext?.cancellationToken`:
`_abortActiveStreams`, `closeResponderResources`, `_runDrain`,
`_handleClientCancellation`, `_onDeadlineExceeded`. After one extra HEADERS frame
none of them reaches the handler's token, and the handler's `RpcCallScope` — where
it registered its cleanup via `context.callScope` — is orphaned: `_cleanupStream`
closes the NEW scope. A peer can therefore make a handler un-cancellable and leak
its disposers with a ~30-byte frame. The original deadline is also replaced by
whatever `grpc-timeout` the second frame carries (or none).

## Witness a round would build

Bidi method whose handler awaits `context.cancellationToken.cancelled` and
registers a disposer on `context.callScope`. Hand-built peer sends HEADERS, then
HEADERS again, then the endpoint is drained. Witness: handler never observes the
cancel; disposer never runs. Guard: without the second frame both happen.

## Fix sketch

Ignore a methodPath metadata frame for a stream that already has a method (or a
responder); at most read encoding hints from it. Never rebuild the context of a
dispatched stream.

## Owner decision

—

## Closed (round 487) — confirmed, and the ping half is a different defect

```
                        handler saw the cancel   disposer ran
second HEADERS                    0                   0
nothing extra (control)           1                   1
```

Fixed as the sketch's first clause says — ignore a methodPath metadata frame for
a stream that already has a method — and the condition was not invented: the
data path has carried it all along (`if (!state.hasMethod && message.methodPath
!= null)`). The sketch's "at most read encoding hints from it" was declined;
nothing asks for it.

Ignored rather than refused, because a peer sending one is buggy and failing a
call that is working is the larger harm. The warning is behind a bool, per
CLAUDE.md.

**The ping sentence is TRUE and this guard does not reach it.** `frames on the
stream id: 2 -> 4` against a control of `2 -> 2`, unchanged by the fix — by the
time the second frame arrives the ping's `onComplete` has run `_cleanupStream`,
so `hasMethod` is false on the fresh state and the frame opens what looks like a
new call on a reused id. That is id-reuse behaviour (RPC-03), not a context
rebuild, and a responder cannot tell a reused id from a new call. Harm: the peer
gets a second pong on a stream it has already released. Not filed as a new lead
— re-open this one if a measurement gives the reuse case teeth.

**Its instrument is worth inheriting.** Counted on `getMessagesForStream(id)`
the ping arm reads `2 -> 2` in both arms and with the fix ablated, because that
controller closes when the ping ends. `incomingMessages` filtered by id is what
sees it.
