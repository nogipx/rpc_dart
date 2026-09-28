---
round: 487
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: P-126 — new
commit: yes
---

# Round 487 — the frame that swaps a running handler's context

## Target

B-96, third in the audit's rank, and the first of these leads whose damage is
reachable by an unauthenticated peer with one ~30-byte frame.

Lens RPC-21, *drive the lifecycle twice*: the defect is what a second opening
frame does to a stream that is already open, which is that lens's Ask applied to
a stream rather than to a transport.

## Hypothesis

`_handleMetadataMessage` runs for every metadata frame carrying a methodPath,
with no check that the stream is already bound. `storeMetadata` clears the
cached context and `_cacheContext` builds a new one, so the running handler is
left holding a token and a call scope nothing can reach. Refuted if some earlier
guard rejects the second frame, or if the handler reads its context afresh.

## Before

```
                        handler saw the cancel   disposer ran
second HEADERS                    0                   0
nothing extra (control)           1                   1
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b96_second_headers.dart`

Both counters are incremented inside the handler's own closure, so they say what
the HANDLER observed rather than what the pipeline believes it sent.

## Mechanism

`setMethodKey` and `storeMetadata` each null `_cachedContext`, and
`_cacheContext` then builds a fresh `RpcContext` — new cancellation token, new
`RpcCallScope`, new deadline timer, the old timer cancelled. The handler is
already running with the first one. Every mechanism that stops a handler reads
`state.cachedContext`, so all five now reach an object nobody holds, and
`_cleanupStream` closes the NEW scope while the handler's disposers sit on the
orphaned one.

The data path had always been guarded — `if (!state.hasMethod &&
message.methodPath != null)` at `_handleDataMessage` — and the metadata path,
which is the one a peer can send at will, was not.

## After

```
                        handler saw the cancel   disposer ran
second HEADERS                    1                   1
nothing extra (control)           1                   1
```

Ignored rather than refused, with a warning that fires ONCE: a peer sending it
is buggy, and failing a call that is working is the larger harm.

## Canary

`if (state.hasMethod && 1 < 0)` — the WITNESS fails with `Expected: <1> /
Actual: <0>`, "the drain reached a token the handler does not hold". The
CONTROL and both GUARDs stay green, including the one that drives a payload
arriving BEFORE its headers — the pre-method replay path the guard sits beside.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` 1935/1935, REUSE 3.3.

## Not fixed

**The lead's second claim is CONFIRMED and is a different defect.** A repeat
ping frame is answered again — `frames on the stream id: 2 -> 4` against a
control of `2 -> 2` — and this guard does not change it, because by the time the
second frame arrives the ping's `onComplete` has already run `_cleanupStream`.
`hasMethod` is false on the fresh state, so the frame opens what looks like a
new call on a reused id, and answering it is what a responder that cannot tell
reused ids apart is supposed to do. The harm is small (the peer gets a second
pong on a stream it has released) and the mechanism is id reuse, which is RPC-03
territory rather than this one. Written into B-96 rather than left in a round
record nobody re-reads.

**The instrument that nearly refuted it** is worth the line: counting on
`getMessagesForStream(id)` reads `2 -> 2` in both arms and with the fix ablated,
because that controller closes when the ping ends. Counting on
`incomingMessages` filtered by id is what shows the second answer.

## Links

Lens RPC-21. Bench P-126 (new). Lead B-96 (closed, with its ping half answered
in place).
