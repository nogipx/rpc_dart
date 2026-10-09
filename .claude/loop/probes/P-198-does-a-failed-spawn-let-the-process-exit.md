---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/b155_spawn_failure_leaks_ports.dart
round: 577
commit: e5f7ad8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
status: valid
---

# P-198 — does a process whose spawn failed still exit?

## Why it exists

B-155 asked the question in the only form it has: "`spawn(customParams: {'x': ReceivePort()})` in a
script; does it exit?" An open ReceivePort keeps the Dart event loop alive, so the symptom is the
ABSENCE of an exit — there is no counter to read and no error to catch.

## The harness

**The probe IS the subject.** It fails a spawn, prints, and returns from `main` with no `exit()` call,
because `exit()` would end the process whatever the ports are doing. The verdict is whether the command
returns at all.

The unsendable value is a `ReceivePort`, which cannot cross an isolate boundary, so `Isolate.spawn`
throws `ArgumentError` while building its message — after the library's three ports are open.

## The numbers (round 577)

```
guard ablated   spawn threw ArgumentError, last line printed, NO EXIT at 25 s / 60 s / 90 s
guard in place  spawn threw ArgumentError, last line printed, exits immediately
```

## Measures

Process termination, as a yes/no. The printed `spawn threw ArgumentError` line is the premise check: a
run where the spawn stopped throwing would exit for the wrong reason.

## Control

**The ablated arm is the control, and it had to be run in that direction** — the fix came first here,
so the "before" reading was taken by switching the guard off. Both readings use the same probe.

## The rig was wrong first, and it read exactly like the defect

The first version passed a `ReceivePort` it never closed. That port held the process open BY ITSELF, so
the probe hung with the fix in place too — indistinguishable from a fix that does not work. Closing the
probe's own port after the attempt is the single line that separates the readings.

A bench whose own resource reproduces the symptom is `measurement.md` item 6 — measure what the library
does, not what the bench does — in a shape worth remembering: here the bench and the subject hold the
same kind of handle.

## What it establishes, and what it does not

Establishes that a throwing `Isolate.spawn` left the process unable to exit, and that closing the three
ports in a catch fixes it.

Does NOT cover anything else on the startup path: everything between the spawn and the handshake already
routes through `teardownStartup`.

Does NOT cover the web bridge, which has its own spawn path (`B-162`'s neighbourhood).

Does NOT establish a time bound. "Never exits" is read as "not within 90 s"; the regression test uses 45
s, which is generous for a process that does one failed spawn but is a judgement rather than a
measurement.

## Reading

rpc_dart_isolate — **the probe IS the subject**: it fails a spawn, prints, and
returns from `main` with no `exit()` call, so the verdict is whether the
command returns at all. `guard ablated -> no exit at 25 s / 60 s / 90 s`,
`guard in place -> immediate`. The printed `spawn threw ArgumentError` is the
premise check. **Its first version was wrong in a way that read exactly like
the defect**: the `ReceivePort` it used as the unsendable value held the
process open by itself, so it hung with the fix in place too — bench and
subject holding the same kind of handle, `measurement.md` item 6. Does NOT
bound the hang: "never exits" means "not within 90 s"
