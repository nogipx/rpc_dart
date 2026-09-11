---
round: 330
scope: packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart
commit: 592505d5
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
---

# C-35 — the bidi bridge's send-failure catch cannot be entered

## The claim that looked true

`caller_pipeline`'s bidi bridge has every ingredient RPC-13 asks for:

```dart
void enqueue(Future<void> Function() op) {          // a VOID function, so
  sendSeq = sendSeq.then((_) async {                // unawaited_futures is blind
    if (!isCleaned) await op();                     // (round 329 measured that)
  });
}
```

`sendSeq` is declared at line 641, assigned at 644, and **never read** — grep
it. Anything the chain throws is abandoned, which in Dart ends the isolate. The
two enqueued ops catch their own send, but the CATCH calls
`controller.addError(e, st)` with no `isClosed` guard, and `cleanup()` closes
that controller. The two SERVER-STREAM bridges in the same file guard every
controller op (lines 442-449 and 580-587); the bidi one does not, which is
RPC-25's drift shape on top of RPC-13's damage.

## Why it cannot happen

`caller.send()` never throws, so the catch is never entered.
`CallProcessor.send` (base_processor:1533) queues through `_transmitRequest`,
whose `_sendSequence` callback (1030) wraps everything in a bare
`catch (e, stackTrace)` and records `_requestSendFailure` instead of
propagating. It then `await _sendSequence` — a future that, by construction,
cannot complete with an error.

So the outer catch is dead for the same reason C-24's was: **every expression it
wraps is already guarded from the inside.**

## Measured

`.dart_tool/probe/bidi_send_failure_after_close.dart`, with a `print` planted in
the catch itself — L-04's amendment, which says instrument the guard before
building a witness for it:

```
arm        scenario                                   catch entered   unhandled
drain      handler consumes, nothing parks                 no             0
cancel     consumer walks away while a send is PARKED      no             0
oversize   maxMessageLengthBytes: 1024, frame refused      no             0
```

Three scenarios, including one that makes the send genuinely illegal. The catch
was not reached once.

## Control

The instrument IS the control, and it is what separates this from three arms
that merely passed. A `print` inside the catch reports whether the guard was
entered, independently of whether anything went wrong — so "0 unhandled" can be
read as "the guard was never asked" rather than "the guard held". Without it,
the same three rows are indistinguishable from a working guard.

Its sensitivity is shown by the `oversize` arm: `maxMessageLengthBytes: 1024`
against a 16 KiB frame is a send the library MUST refuse, and the refusal is
visible — the call fails — while the catch still does not fire. That is the rig
demonstrating it can drive a send failure and that this handler is not on its
path.

## What would change this

The negative rests on `_transmitRequest`'s bare catch. Narrow that catch, or add
a send path that bypasses `_sendSequence`, and the outer handler becomes live —
at which point the missing `isClosed` guard and the unawaited `sendSeq` both
matter at once. Both are cheap to add and neither is worth adding blind: see
L-04 case 2.

> **A guard can be dead because a DIFFERENT class guards its input.** Round 235
> made `detach()` unable to reject, which left a `.then()` safe by a property of
> another method; here `base_processor` makes `send()` unable to throw, which
> leaves `caller_pipeline`'s catch unreachable. Neither file says so, and the
> safety is one narrowed `catch` away from evaporating in a file nobody is
> editing at the time.
