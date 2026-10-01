---
status: closed (round 577)
round: 577
commit: e5f7ad8a
release: changelog
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: P-198
reason: "bench — CONFIRMED exactly as filed, at its stated confidence: a spawn that throws left three open ReceivePorts and the process never exited (no exit at 25 s, 60 s or 90 s); with the guard it exits immediately"
---

# B-155 — isolate: three ReceivePorts stay open when Isolate.spawn throws

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`initPort`, `errorPort` and `exitPort` are opened before `await Isolate.spawn(...)` with no try; an unsendable `customParams` value makes spawn throw and the open ports keep the process alive.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:312-328`; `teardownStartup` exists only after.

## Why it matters

A CLI or test process that fails to spawn never exits.

## Witness a round would build

`spawn(customParams: {'x': ReceivePort()})` in a script; does it exit?

## Fix sketch

try/catch closing the three ports.

## Outcome (round 577) — confirmed exactly as filed

`../rounds/577-the-process-that-could-not-exit.md`. Bench `P-198`.

```
guard ablated   spawn threw ArgumentError, NO EXIT at 25 s / 60 s / 90 s
guard in place  spawn threw ArgumentError, exits immediately
```

High confidence, and right. `teardownStartup` closes exactly these three ports but is defined after the
await and needs the `isolate` that await produces, so it can never cover the throw. The fix is a catch
that closes them and rethrows; no subscriptions exist yet, so there is nothing else to unwind.

**The rig was wrong first and read exactly like the defect.** The probe's own `ReceivePort` — the
unsendable value — held the process open by itself, so the first version hung WITH the fix in place,
indistinguishable from a fix that does not work. Closing the probe's own port is the line that separates
the readings (`measurement.md` item 6, in a shape where bench and subject hold the same kind of handle).

**The witness is a SUBPROCESS**, since process exit is not something a test can assert about itself —
round 323's shape. The fixture does not call `exit()`, and the test checks `threw ArgumentError` in its
output first so a spawn that stopped failing cannot read as a pass.

Not covered: the web bridge's own spawn path, and anything between the spawn and the handshake, which
already routes through `teardownStartup`. The test's 45-second bound is a judgement rather than a
measurement.

## Owner decision

—
