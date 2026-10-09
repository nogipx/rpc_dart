---
file: packages/core/rpc_dart/.dart_tool/probe/b207_what_a_refused_bomb_leaves_behind.dart
round: 591
commit: 30ed998b
paths: [packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
status: valid
---

# P-209 — what a refused bomb leaves behind

## Why it exists

B-207 says the decompression limit throws from inside `sink.add`, jumping over
`sink.close()`, so the native zlib filter is left to a finaliser — "at a rate the
peer chooses". The mechanism is a reading; the RATE is the claim, and that needs a
number.

## The harness

20000 decompressions on each arm, same decoder, same call site, one difference:
whether the payload trips the limit.

```
CONTROL  a 51-byte payload expanding to 16 KiB under a 1 MiB limit   reaches close()
WITNESS  a 4098-byte payload expanding to 4 MiB under a 1 MiB limit  throws, skips close()
```

GC is deliberately NOT encouraged between arms. The claim is that release happens at
a finaliser rather than at the throw, so a reading taken after a forced collection
would measure the finaliser doing its job and say nothing about when.

The last block drives the sketch's own fix — `close()` after the throw — and reports
what the caller is told, because an exception from a `finally` REPLACES the one in
flight.

## The numbers (round 591)

Three runs, `CONTROL` then `WITNESS`:

```
2000 attempts    +12 MiB   +12 MiB
20000 attempts   +30 MiB    +6 MiB
20000 attempts   +31 MiB   -53 MiB
```

The price of the fix:

```
bomb      caller gets FormatException; close() after the throw was CLEAN
ordinary  no throw at all
```

## Measures

Resident growth across 20000 refusals, against 20000 successful decompressions as
the control, and the exception identity a `close()`-in-`finally` would produce.

## Control

**The successful arm is the control and it grows MORE than the witness, every run.**
That is the reading: if the skipped `close()` accumulated native filters, the witness
would be the arm that climbs. The third run has it handing 53 MiB back to the
collector mid-arm.

## What it establishes, and what it does not

Establishes that 20000 refusals accumulate nothing, and that the sketched fix is free
of the hazard it looked like it had.

**Does NOT create the condition under which the claim could still be true** — low GC
pressure — and cannot, which is the round's actual finding: tripping the limit
requires allocating up to the limit, so the refusal path generates the very pressure
that runs the finaliser. A peer cannot ask for a refusal cheaply.

Does NOT read the native side directly. Dart exposes no handle on an outstanding
zlib filter, so RSS is the only observable, and RSS here is the whole process — fine
for a probe run alone, not for a test (see B-224).

## Reading

rpc_dart — **the control is the arm that GROWS, which is the whole reading**:
20000 successful decompressions (reaching `close()`) against 20000 refusals
(skipping it) give `+12/+12`, `+30/+6`, `+31/-53` MiB across three runs. If
the skipped close accumulated native filters the witness would be the climbing
arm; it is not, and once it handed 53 MiB back mid-arm. **GC is deliberately
not encouraged between arms** — the claim is that release happens at a
finaliser rather than at the throw, so a forced collection would measure the
finaliser working and say nothing about when. Cannot create the one condition
that would keep the claim alive (low GC pressure) and explains why: tripping
the limit requires allocating up to it. Also prices the sketched fix, which
turned out free — `close()` after the throw is clean
