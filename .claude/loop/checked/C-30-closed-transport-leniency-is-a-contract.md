---
round: — (not re-measured)
commit: 54b4c5ab
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_isolate/lib/**]
scope: [core, isolate]
---

# C-30 — A closed RpcChannelTransport is lenient on purpose

Resolved at 60a57ead; imported from private memory after round 239 for the two
rules it establishes. **Do not "fix" the leniency.**

`createStream()` and `sendMetadata()` do NOT throw on a closed
`RpcChannelTransport`, though `RpcHttpCallerTransport` and
`RpcHttp2CallerTransport` both do — which is exactly why those two never had the
defect below. **Three tests pin it**, one named *"use after close fails cleanly
(no throw, no delivery)"* with *"Sending after close must not throw; the message
is silently dropped"* beside it. A first fix attempt added the throw, the gate
caught all three, and it was backed out. The asymmetry is deliberate — see
`C-28`'s list of sibling differences that are not defects.

**What WAS the defect**, and what it was fixed with instead: a call on a closed
transport raised an *unhandled* async error, ending the process outside a
guarded zone. Reached in `rpc_dart_isolate` whenever the worker dies mid-call
and the host makes one more call.

```
  before : Unhandled exception: RpcStatusException(14): Stream closed without
           receiving response      (no stack frames at all)
  after  : the call throws RpcStatusException(14) like any other failure
```

> **Microtask delivery is not enough — use a timer.** The caller creates its
> completer, subscribes to `getMessagesForStream`, and only THEN returns the
> future the application awaits, all in one microtask chain. An error raised on
> a microtask — `const Stream.empty()`'s eager done, or `Stream.error`, which was
> tried and did not help — lands on a future with no listener, and Dart reports
> it unhandled at that instant; attaching later does not retract it. A timer
> callback runs only once the microtask queue drains, by which point the await
> is in place. The fix returns
> `Stream.fromFuture(Future.delayed(Duration.zero, () => throw ...))`.

> **Testing an "unhandled error" claim:** wrap the body in `runZonedGuarded` and
> assert the handler collected NOTHING. Asserting only that the call throws is
> not enough — the crash happens even when the call also fails correctly.

The quiet-close property is the trap this contract creates, and it has its own
consequence for wrappers: delegating into a closed `RpcChannelTransport` does
not throw, it silently produces an empty stream, so a wrapper must never hand
work to one. See `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`.

## Control

The three tests that pin the leniency ARE the control, and they fired: the
attempt to make it throw failed all three at once. A contract nothing enforces
would have let that change through silently.
