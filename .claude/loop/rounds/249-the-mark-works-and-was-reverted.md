---
round: 249
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-15
bench: P-11 — reused
commit: no
---

# Round 249 — the mark works, and was reverted

## Target

B-22 again, continuing round 248: build the per-stream mark the owner
authorised, now that 248 had shown why the one-line version cannot work.

## Hypothesis

A mark that records "this stream's debt was settled at forget" lifts the wedge
without letting a late drain credit the connection twice.

## Before

P-11's control was re-run first, as reusing a bench requires, and still
separates:

```
P-11 case C (receiver binds and PAUSES)
  KiB per call     [256, 256, 256, 256, 0]
  total sent       1024 KiB
  wedged at call   4
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/conn_window_leak.dart` (P-11).

## Mechanism

As round 248 established: `_fcForget` defers the repay to a consumer whose
`onCancel` a paused subscription never reaches.

## After

Four edits — a `_fcRepaidAtForget` set; `_fcForget` repaying unconditionally and
marking a stream that still has a live listener; `_fcCredit` gaining
`{bool creditConnection = true}`; `_fcOnConsumed` passing
`creditConnection: !_fcRepaidAtForget.contains(id)`, with the mark dropped in
`onCancel`:

```
P-11 case C            before        after
  total sent         1024 KiB      3072 KiB
  wedged at call            4         never
```

Case B, the draining control, stayed at 3072 KiB and never wedged, and the core
suite passed 1417 tests — ordinary traffic is still credited.

## Canary

**Two of the three arms round 231 named, and the third does not exist.** The
wedge lifts and ordinary traffic is still credited; a consumer that drains AFTER
forget must not credit the connection twice, and nothing tests it.

## Gate

Not run to completion: the change was reverted before the workspace gate.
`git status` clean and analyze green afterwards, so the revert is exact.

## Not fixed

All of it, deliberately. Shipping a flow-control change on two of three arms,
where the missing one guards a window that would inflate past its configured
size, is what the canary rule refuses. B-24 was explicitly authorised to ship
without a witness; B-22 was not, and its decision text asks for that arm by name.

The four edits are quoted verbatim in `77ee136a` and in the lead, so the round
that finishes this re-applies rather than re-derives.

## Links

Lens RPC-15 · bench P-11, reused and re-validated · lead B-22 · round 248 is
the half that found the mechanism.
