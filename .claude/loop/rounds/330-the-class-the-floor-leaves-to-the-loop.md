---
round: 330
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-13
bench: none
commit: yes
---

# Round 330 — the class the floor leaves to the loop

## Target

Round 329 established that the analysis floor does not cover RPC-13's class:
`unawaited_futures` fires only inside an `async` body, and round 242's defect
lived in a `void` method. That makes the loop the only thing that can sweep it,
and it narrows the surface usefully — the async-context sites are now the
gate's, so only the sync-context ones need reading.

## Hypothesis

With the lint holding the async half, a sweep of the `.then(` sites in
sync/void contexts will find an unguarded one on a user-code path.

## Before

The detector across RPC-13's five packages:

```
.then(      15 hits, of which 2 are comments   ->  13 sites
  with an onError / catchError                      6
  WITHOUT                                           7
unawaited(  85 hits                                     (round 222's sweep)
```

Seven unguarded. Five resolve immediately on reading:

```
base_processor.dart:334, 1030, 1584   each callback ends in a bare
                                      `catch (e, stackTrace)` -- cannot fail
isolate_transport_web.dart:323, 391   Future.any arms, awaited by spawn()
client_connection.dart:432            round 242's site; _emit is guarded there
```

The seventh is `caller_pipeline.dart:644`, and it has every ingredient the lens
asks for:

```dart
void enqueue(Future<void> Function() op) {          // VOID -> the lint is blind
  sendSeq = sendSeq.then((_) async {
    if (!isCleaned) await op();
  });
}
```

`sendSeq` is declared at 641, assigned at 644 and **never read**. Both enqueued
ops catch their own send — but the CATCH calls `controller.addError(e, st)` with
no `isClosed` guard, and `cleanup()` closes that controller. **The two
server-stream bridges in the same file guard every controller op** (442-449,
580-587); the bidi one does not.

## Mechanism

It cannot be entered. `caller.send()` never throws: `CallProcessor.send`
(base_processor:1533) queues through `_transmitRequest`, whose `_sendSequence`
callback wraps everything in a bare catch and records `_requestSendFailure`
rather than propagating, then awaits a future that by construction cannot fail.

Two probe rebuilds went to scenarios that never reached the catch before the
cheaper move — **instrument the guard, which is L-04's own amendment and is
written down two directories away.** A `print` inside the catch answered in one
run what the scenarios could not:

```
arm        scenario                                   catch entered   unhandled
drain      handler consumes, nothing parks                 no             0
cancel     consumer walks away while a send is PARKED      no             0
oversize   maxMessageLengthBytes: 1024, frame refused      no             0
```

## After

No change. `../checked/C-35-the-bidi-send-catch-is-unreachable.md` records the
negative and what would revive it.

## Canary

n/a — nothing fixed. The instrument is the control: it distinguishes "the guard
held" from "the guard was never asked", which is the distinction L-04 exists for
and the one three passing arms alone cannot make.

## Gate

No code changed — the instrument was reverted and `git status` is empty.
`rpc_dart`'s `lib/` analyses clean and `test/endpoint/` is `+229`. Last full
gate at round 328.

## Not fixed

**The missing `isClosed` guard stays, and so does the unawaited `sendSeq`.**
Both are one line. Neither is worth adding blind: L-04 case 2 says a guard for
an unreachable path costs rounds and buys nothing, and C-24 is the precedent
where exactly that was accepted.

What makes it uncomfortable, and what C-35 records: the safety belongs to a
DIFFERENT file. Narrow `_transmitRequest`'s bare catch in `base_processor.dart`
and the bidi bridge becomes live, with two defects at once, in a file nobody
would be editing at the time. Neither file says so.

## Links

RPC-13 (`applied:` gains 330) — the sweep narrowed by round 329's finding, which
is the first time the lint floor has usefully SHRUNK a lens's surface rather
than duplicating it. C-35 new. L-04's amendment for the method that ended it,
and C-24 for the same shape one bridge over.

RPC-25 also applies and is worth noting: three bridges in one file, two guarding
their controller and one not, is the drift that lens is about — it just happens
to be harmless here.
