---
round: 449
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-103 — new
commit: yes
---

# Round 449 — the window was real, the loss was not

## Target

B-76, next on the rank, and decided by the owner: port the websocket's
`_disconnected`-before-the-await guard to http2 and to the proxy FIRST, then
unify the three machines.

Step one was measured before it was carried out, and it turned into the round.

## Hypothesis

http2 sets `_disconnected` only in its catch, so during `await factory()` the
flag is false, `_ensureUsable` passes, and a send goes into a connection that is
already gone — accepted and dropped silently, which is what the websocket
sibling's comment says the shape costs.

## Before

```
control, no reconnect        ACCEPTED (no error)
during the factory await     RpcStatusException code=14
after reconnect completed    ACCEPTED (no error)

during the await: health=degraded  disconnected=false
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/send_during_the_factory_await.dart`

**`disconnected=false` confirms the window exactly as described.** The send is
refused anyway: the old connection is discarded before the await, so the send
path answers UNAVAILABLE. The controls on both sides of the window are what make
that a reading rather than a harness that refuses everything.

The proxy was settled by READING and structurally: `_retire` and `detach` null
`_inner` before any factory runs, and `_require()` throws on a null inner. There
is no flag whose timing could be wrong, because the guard is the absence of the
transport rather than a boolean about it.

## Mechanism

Nothing to fix on the claim as filed. The guard the decision wanted ported is
redundant on http2 — the connection is gone, and a send to a discarded
connection raises on its own — and structurally impossible to need on the proxy.

## After

n/a — no source change. The claim is a negative: `checked/C-48`.

## Canary

n/a for the claim. The instrument's own sensitivity is carried by the two control
arms: the same send ACCEPTED before and after the window, so the refusal inside
it is the window.

## Gate

No source changed, so the gate is the journal's: `loop.py lint` green. The probe
is new and gitignored under `.dart_tool/`.

## Not fixed

**What remains of B-76 is a different defect from the one it was filed for, and
it is real.** The three machines refuse with three different answers, and http2
disagrees with itself depending on timing:

```
websocket   _disconnected before the await   FAILED_PRECONDITION
http2       old connection discarded         UNAVAILABLE   (during the await)
http2       _ensureUsable, flag set          FAILED_PRECONDITION
the proxy   _inner = null, _require()        FAILED_PRECONDITION
```

http2's `_ensureUsable` carries a comment saying its code matches the websocket
sibling *deliberately*, because the state "used to surface as StateError there
and RpcStatusException here, so no single `catch` covered both". Timing alone
undoes that care. FAILED_PRECONDITION says *call reconnect()*; UNAVAILABLE says
*retry* — so a caller's strategy depends on how far into a reconnect its send
landed.

B-76 stays OPEN, re-scoped to that, with the silent-drop claim struck. The
websocket arm was READ, not benched, and finishing the table is the next round's
job.

**The owner's decision is spent**: step one (port the guard) is refuted, step two
(unify the three) survives and is now about the ANSWER rather than the mechanism.

## Links

- RPC-25 — three machines, and the divergence is in what they TELL the caller
- P-103 — a send during the reconnect factory await
- C-48 — no machine drops a send during its factory await
- B-76 — re-scoped, not closed
- L-13 — the decision re-measured before being carried out, and step one refuted
