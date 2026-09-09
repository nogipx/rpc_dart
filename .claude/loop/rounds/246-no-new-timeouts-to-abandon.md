---
round: 246
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-14
bench: none
commit: no
---

# Round 246 — no new timeouts to abandon

## Target

RPC-14, `swept here (round 223, 0e7b984a)`, four files moved since — the last
stale sweep on core after 243, 244 and 245 cleared the others. Its damage class
is unbounded growth, and on this project the price is a leaked isolate rather
than a socket.

## Hypothesis

Rounds 234-245 added a `.timeout(` around something that holds a handle, or an
await another path can interleave with while a resource is unowned.

## Before

Both halves of the detector, over the diff rather than the whole tree — which is
what a STALE sweep is for:

```
files moved under the lens's paths since 0e7b984a        4
`.timeout(` sites added by those changes                 0
awaits added on resource-holding paths                   2
of those, unguarded                                      0
```

The two awaits:

    await _innerSub?.cancel();                       inside detach's try/catch
    unawaited(inner.close().catchError((_) {}));     attach, when already closed

No bench: the detector is a grep over a bounded diff, and the question about each
hit is answered by reading it.

## Mechanism

n/a — nothing found.

## After

n/a

## Canary

n/a

## Gate

Nothing shipped; the tree at cd6ee68e is green.

## Not fixed

Nothing found. Worth recording WHY the second line is not a finding, because it
looks like one: `unawaited(inner.close().catchError((_) {}))` in `attach()` is
the lens's own prescribed fix, not a violation of it. A proxy that is already
closed cannot hold the transport it was just handed, so it adopts it and closes
it — "the fix, since a Future cannot be cancelled, is to ADOPT the abandoned
one". Round 235 put it there for exactly that reason.

The first line is the one round 235 measured: an unguarded cancel there dropped
a transport instead of closing it (leaked 1, unhandled 1). It is guarded now,
and that guard has a witness — `detach_survives_a_throwing_cancel_test`.

## Links

Lens RPC-14, re-swept: status moves to `swept here (round 246, cd6ee68e)` ·
refines catalog U-17 · the wider family it names is the one round 241 measured
on http2 (B-25) — the loser of a race holding a resource nobody owns.
