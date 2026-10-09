---
round: 577
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-13
bench: P-198 — new
budget: probes 2/5, canaries 2/5
commit: yes
release: changelog
---

# Round 577 — the process that could not exit

## Target

`B-155`, the first measured lead in the isolate cluster — ten audit items filed there in 2026-09-28
and nothing run against any of them. Picked over its siblings because its damage needs no device and
its trigger is written into the lead: `spawn(customParams: {'x': ReceivePort()})`.

Lens RPC-13: an async failure path nobody unwinds.

## Hypothesis

`initPort`, `errorPort` and `exitPort` are opened before `await Isolate.spawn(...)` with no guard, so a
spawn that throws leaves three open ReceivePorts and the event loop never drains.

## Before

```
guard ablated
  spawn threw  ArgumentError
  main is returning now; if this process hangs, the ports leaked
  ... no exit at 25 s, 60 s or 90 s
```

**The process never exits.** `teardownStartup` exists and closes exactly these three ports, but it is
defined after the await and needs the `isolate` the await produces, so it cannot cover the throw.

Probe:
`packages/transport/rpc_dart_isolate/.dart_tool/probe/b155_spawn_failure_leaks_ports.dart`. The fix came
first here, so this reading was taken by switching the guard back off.

## The rig was wrong first, and it read exactly like the defect

**The probe's own `ReceivePort` — the unsendable value — held the process open by itself.** So the first
version hung with the fix in place as well, which looks like a fix that did not work and is really an
arm that cannot see anything: an open ReceivePort keeps the loop alive whoever owns it. The probe now
closes its own port after the attempt, and that single line is what separates the two readings.

`measurement.md` item 6 in a new shape: measure what the LIBRARY does, not what the bench does.

## Mechanism

Three ports, no `try`. The whole fix is a catch that closes them and rethrows — no subscriptions exist
yet at that point, so there is nothing else to unwind.

## After

```
guard in place
  spawn threw  ArgumentError
  main is returning now; if this process hangs, the ports leaked
  exits immediately
```

Same probe, same unsendable value, same throw — only the guard differs.

## Canary

```
`if (1 > 0) rethrow;` ahead of the three closes

  a process whose spawn failed still exits
    Expected: not <-1>
      Actual: <-1>
    three ReceivePorts left open by a failed spawn keep the event loop alive,
    so the process never exits
```

**The witness is a SUBPROCESS**, because process exit is not a thing a test can assert about itself —
the shape round 323 needed for its own absence-witness. The fixture
(`test/fixtures/spawn_failure_must_exit.dart`) deliberately does not call `exit()`, which would end the
process whatever the ports are doing, and the test asserts `threw ArgumentError` in its output first so
a spawn that stopped failing cannot read as a pass.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_isolate +92
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2196 / 2196, REUSE compliant
```

## Not fixed

**Only the `Isolate.spawn` throw is covered.** Everything between the spawn and the handshake already
routes through `teardownStartup`; what this round did not examine is whether any step BEFORE the three
ports are opened can throw, which would be harmless, or whether `entrypointWrapper`'s own construction
can.

**The web bridge was not driven.** `isolate_transport_web.dart` has its own spawn path and B-162 is a
separate lead about it; nothing here says whether it leaks the equivalent.

**The 45-second bound in the test is a judgement.** The fixture does one failed spawn, so a process
that will exit does so in well under a second; the bound is generous rather than measured, and on a
machine loaded past that it would read as a leak.

## Links
Lead `../backlog/B-155-isolate-spawn-failure-leaks-ports.md` — CLOSED.
Lead `../backlog/B-162-isolate-web-ondone-starts-the-entrypoint.md` — the web spawn path, untouched.
Bench `../probes/P-198-does-a-failed-spawn-let-the-process-exit.md` — new.
Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [577]`.
Lesson: none. `measurement.md` item 6 is what the rig error cost, and it is already written; the
instance is recorded above because the failure mode — a bench whose own resource reproduces the
symptom — is worth a reader's time.
