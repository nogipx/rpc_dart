---
round: 329
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none
commit: yes
---

# Round 329 — what the floor does not catch

## Target

RPC-26, four rounds old and three-for-three, carrying a `breaks:` line I wrote
and never tested:

> wrong result: an unchecked implicit downcast from `dynamic` throws at run time
> where the analyser could have refused it, and the class stays invisible to CI
> so every instance costs a round.

RPC-15's whole subject is the loop's claims about its own fixes, and its own
evidence is round 211 catching round 206 doing this. A lens that has just
consumed three rounds and 534 edits is the most expensive thing in the journal
to leave unverified.

## Hypothesis

Both halves of that line hold: some of the 534 issues were live, and the floor
now guards a class the loop has been finding by hand.

## Before

**Half one fails on the record already in the journal.** Rounds 325, 326 and 328
fixed 320 + 211 + 3 issues, and each reported every test count in the workspace
unchanged:

```
                round 324 (before)   round 328 (after)
rpc_dart            +1435 ~1             +1435 ~1
rpc_dart_http2      +204                 +204
rpc_dart_websocket  +137                 +137
rpc_dart_isolate     +74                  +74
```

534 edits, zero behaviour moved. Not one of them was a live defect.

**Half two fails to a three-line probe.** Round 242's defect — an unguarded
`.then()` running user code, which ends the isolate when it throws — is still in
the tree in the shape RPC-13 describes, and the floor calls it clean:

```dart
// client_connection.dart:432, analysed green under the strict floor
_proxy.detach().then((_) {
  if (_isStopped) return;
  _emit(const RpcClientOffline());   // _emit calls user code
  _connectWithBackoff();
});
```

Probing where `unawaited_futures` stops looking:

```
void inVoidFunction()           { work().then((_) {}); }          not flagged
Future<void> inAsyncFunction()  async { work().then((_) {}); }    FLAGGED
void withNestedVoid()           { void inner() { work(); } … }    not flagged
```

Probe: `packages/core/rpc_dart/lib/src/_floor_probe.dart`, written for this and
deleted.

## Mechanism

`unawaited_futures` fires only inside an `async` body. A `void` method is
exactly where a fire-and-forget future is most likely to be written and least
likely to be awaited, and that is where round 242 found its crash.

The same holds across the set: nothing in the floor addresses RPC-01 (credit on
skip), RPC-05 (charge point), RPC-14 (timeout abandons work), RPC-16 (check
before await) or RPC-17 (limit after residency). **A lint floor and a defect
lens cover different things, and the overlap is smaller than it looks.**

## After

RPC-26's `breaks:` corrected to say what was measured — the damage is a
permanently unguarded surface, LATENT on this corpus, not a live defect — and a
new section records what the lens does not buy, so a green gate is not read as
coverage of the classes rounds are spent on.

## Canary

n/a — nothing was fixed. The probe IS the control: the same expression in three
contexts, one flagged and two not, which is what makes "the floor misses round
242's shape" a measurement rather than an inference.

## Gate

No code changed; the probe file was deleted and `rpc_dart`'s `lib/` re-analysed
clean. Last full gate at round 328: analyze clean over 21 packages plus
`rpc_dart_wasm`, `format:check` clean, `test:unit` 14 packages 0 failures.

## Not fixed

`client_connection.dart:432` is left as it is. Round 242 fixed the reachable
half by guarding `_emit`, and this round only establishes that the LINT does not
also guard it — re-opening the defect would need a witness, and RPC-13 already
owns that thread.

The three rounds RPC-26 cost were not wasted — 534 latent issues closed
permanently is a fair return — but the lens now says so in those terms instead
of implying it caught something.

## Links

RPC-15 (`applied:` gains 329) — the lens is about re-measuring the loop's own
records, and this is the first time it has been pointed at a lens created inside
the same ten rounds rather than at one grown stale.

RPC-26 corrected. RPC-13 for the class the floor does not cover, and round 242
for the instance that proves it.
