---
round: 500
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-13
bench: P-138 — new
commit: yes
---

# Round 500 — ask the primitive first

## Target

B-109, sixteenth in the audit's rank.

Lens RPC-13 — the async-error and subscription-hygiene lens, whose detector is
"every `listen` and every abandoned future in these paths". This lead is that
detector's subject matter with the question inverted: not whether a callback
escapes, but whether one is retained.

The lead's whole mechanism is a claim about a Dart primitive rather than about
this library, so the round asked the primitive before hunting for a leak — twelve
lines, no library code, and it settles the lead.

## Hypothesis

Cancelling a `Future.asStream()` subscription does not detach the callback, so a
long-lived token accumulates one per call. Refuted if cancelling detaches, or if
no site uses that form.

## Before

```
100 asStream subscriptions, CANCELLED    -> callbacks fired =   0
100 asStream subscriptions, left open    -> callbacks fired = 100   <- control
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b109_token_listeners.dart`

**REFUTED at the primitive.** Cancelling detaches, so nothing accumulates however
long the token lives.

The control is what makes the zero admissible: same loop, same future, one line
different. A bench running only the cancelled arm would report the same zero with
its counter unwired.

## Mechanism

None — there is no defect. What the round did instead was a census, because the
primitive alone is not the whole answer: a site observing the token with a bare
`.then(` WOULD retain its callback until the token completed, and that is the real
version of this concern. All six observers in `lib/` use
`asStream().listen(...)` with a stored subscription, and all six cancel it;
`grep` for `cancelled.then(` and `cancelled.whenComplete` returns nothing.

The sixth site is `ping.dart:244`, added by round 499 one round earlier — so the
census also checked this round's own predecessor.

## After

n/a — nothing changed.

## Canary

n/a for a fix. The control arm is the equivalent and is described above.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant. Nothing in `lib/` changed.

**`test:unit` went RED first, on a test round 496 shipped four rounds ago, and the
flake is mine.** `the_parser_reassembles_linearly_test` compared a 16 MiB arm
against a 2 MiB arm and required the ratio under 24x. It failed in the full run
and passed alone and on re-run: with fifteen packages' suites in parallel the two
arms are scheduled differently, and a descheduled large arm inflates the ratio
with nothing wrong.

`methods/tests.md` item 3 names exactly this — *never compare two independently
measured runs as a ratio; check both against one absolute bound.* Repaired to one
arm against 400 ms, which is 40x the fixed cost (8 ms) and a quarter of the
quadratic one (1515 ms), so load must make the machine 40x slower before it cries
defect and the defect must get 4x faster before it hides. Re-canaried: exact-fit
growth restored reads `1289530us` against the bound, so the wider form still
bites.

## Not fixed

**Nothing to fix.** The negative is `checked/C-58`.

**The sketch's API is now a change with no defect behind it.** Giving
`RpcCancellationToken` an `addListener`/`removeListener` pair would still be the
clearer contract — a `Completer` used as a broadcast notification is an idiom that
invites exactly this doubt, which is presumably why the audit raised it — but that
is a design preference and the owner's.

**Level 2 of the bench produced nothing usable and the record says so.** 20 000
calls with a shared token against a fresh one per call gave `+24096 KiB` and
`-25504 KiB`, and an earlier run of the same code gave `-3424` and `-160`. RSS
across arms is GC noise; P-128 paid for that lesson and this round paid a second
instalment by reaching for it anyway.

## Links

Lens RPC-13. Bench P-138 (new). Negative `checked/C-58`. Lead B-109 (closed).
Round 499 added the sixth observer this round's census covers.
