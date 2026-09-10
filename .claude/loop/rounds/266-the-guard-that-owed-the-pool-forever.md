---
round: 266
verdict: FIXED
packages: [rpc_dart]
lens: RPC-05
bench: P-11 — reused
commit: yes
---

# Round 266 — the guard that owed the pool forever

> **Why 251-265 have no files of their own, and `lint` is right to say so.**
> They were not separate rounds by this loop's own definition — one target, one
> verdict, one record. They were one round on B-22 that took fifteen turns: five
> witness designs, each built, canaried and refuted, plus the read that
> explained why none of them could work. Their record is B-22's lead, which
> carries every design and every disproof, and the commits that made them.
> Numbering each turn was the mistake; the gap is the honest shape of what
> happened, and closing it by inventing fifteen files would be worse.

## Target

B-22, decided by the owner and open since round 231. Rounds 248-265 all went at
it; this is the one that ships.

## Hypothesis

`_fcForget` can repay the connection pool unconditionally without over-crediting
anything that matters.

## Before

P-11, whose control was re-run first and still separates:

```
CASE C — receiver binds and PAUSES (never drains)
  KiB sent per call  [256, 256, 256, 256, 0]
  total sent         1024 KiB
  wedged at call     4
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/conn_window_leak.dart`.

## Mechanism

Two paths repay the pool and a paused consumer reached neither. The stream
controller's `onCancel` runs "on an explicit cancel and again when a closed
controller reaches `done`" — and a PAUSED subscription never receives `done`.
`_fcForget` skipped the repay precisely because a listener existed. So the bytes
stayed owed for the life of the connection, and every later call on it paid.

The guard was there to prevent a double credit: a still-attached consumer may
drain afterwards, and `_fcCredit` credits the connection unconditionally. That
fear is unfounded, which took five failed witnesses and one read to establish —
the receiving side clamps an incoming grant at its own window
(`channel_transport.dart:1166-1174`, *"a peer must not be able to raise our
ceiling"*). The defence against a hostile peer absorbs our own double
accounting, and `_fcConnPending` resets on every grant, so nothing accumulates
on this side either.

## After

```
CASE C — receiver binds and PAUSES (never drains)
  KiB sent per call  [256 x 12]
  total sent         3072 KiB
  wedged at call     never
```

Same probe, matching the draining controls exactly.

## Canary

**The witness is P-11 itself**, and it is a real one: restoring the
`hasListener` guard puts case C back to 1024 KiB and wedged at call 4, measured
repeatedly across rounds 249-265. Case B, the draining control, is unchanged at
3072 KiB throughout, so the probe separates the defect from "flow control
stopped working".

The double-credit arm has NO witness and needs none: five designs failed to
observe an over-credit (rounds 253, 254, 262, 263, 264) and round 265 explained
why — there is nothing to observe, the clamp absorbs it. That is recorded rather
than papered over, and `forget_does_not_double_credit_test.dart` stays as a
GUARD on the clamp's invariant, labelled in its own header as not being evidence
for this fix.

## Gate

`melos run analyze` SUCCESS (21 members + wasm) · `melos run test:unit
--no-select` SUCCESS · `melos run format:check` SUCCESS · `melos run
license:check` REUSE compliant. In the package: analyze clean over lib and test,
`fvm dart test -j 8` 1421 passed / 1 skipped.

## Not fixed

The fix is one line, and the eighteen rounds before it were spent proving a
danger that does not exist. Round 248 proposed exactly this change and talked
itself out of it on a plausible argument nobody measured; the cost of that
plausibility was rounds 249-265.

## Links

Lead B-22, closed · bench P-11, reused · lens RPC-05 (where a limit is charged
and released) · the diagnostics field added in round 262
(`flowControlConnectionCredit`) stays, since it is what made round 265's read
checkable.
