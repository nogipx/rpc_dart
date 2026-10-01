---
round: 550
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-178 — reused
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
---

# Round 550 — a queue depth for an object

## Target

B-106, decided by the owner on round 549's measurement: **add the per-stream queue-depth
ceiling**, because it is safe under both the minting and the holding shape and no usage
frequency has to be established first.

Lens RPC-17: a limit that fires after residency. Here it is a limit that never fired at all.

## Hypothesis

`RpcStreamBufferLedger` charges `message.bufferedBytes`, which is 0 for a `directPayload`. The
mechanism that bounds un-consumed buffering therefore admits an unbounded number of direct
objects and charges nothing for any of them.

## Before

```
  arm                                      queue cost   (nominal 400 MiB)
  HOLDING, paused per-stream consumer         -33 MiB
  MINTING, paused per-stream consumer         270 MiB
```

Bench `../probes/P-178-minting-against-holding.md`, with its consumer moved onto the
per-stream path — see below.

## Mechanism

The ledger gains an EVENT dimension beside its byte one. Both are charged on every inbound
message and whichever ceiling is reached first binds, so a codec payload is bounded as before
and a direct object is bounded by depth.

`maxBufferedMessagesPerStream` is the new policy field, default 1024. Its doc states what it
counts and why it counts that and nothing else: what one object weighs is the application's to
know, the same object may or may not be retained elsewhere in the process, and the measurement
says a depth bounds both shapes without having to tell them apart. That is the B-209 / B-128
lesson applied before the field ships rather than after.

**Three places needed the count and not just the bytes**, each of which would have been a
defect of its own:

- `release` returns the event charge even for a message carrying no bytes — otherwise a
  zero-copy stream is admitted `limitEvents` times and refused for ever after, which is the
  bound-without-release inversion round 536 recorded;
- `forget` and `clear` drop the count, or a reused stream id inherits a full queue;
- `trackedStreams` counts either dimension, since a zero-copy stream holds events and no bytes
  and read as tracking nothing.

The overflow message now names WHICH ceiling fired. A count overflow reported as a byte
overflow names a number the stream never approached — and for a direct object that number is
always 0.

## After

```
  arm                                      queue cost   (nominal 400 MiB)
  HOLDING, paused per-stream consumer         -33 MiB
  MINTING, paused per-stream consumer         270 MiB
  MINTING, paused, depth 64                    71 MiB   <- 64 messages x 1 MiB
```

The bound lands where it is configured. `-33 MiB` on the holding arm is the decision's premise
holding up: the ceiling costs that shape nothing, because the objects exist either way.

## The probe had to be moved, and that is the round's sharpest finding

**There are TWO queues on the receive path**, and the first version of the bounded arm measured
the wrong one:

```
  MINTING via incomingMessages, depth=64   355 MiB   <- a ceiling that "does not work"
  MINTING via getMessagesForStream, d=64    71 MiB   <- the same ceiling, working
```

Subscribing to `incomingMessages` — the connection-wide broadcast — leaves `_streamControllers`
empty, so the per-stream ledger is never charged at all. The reading looked exactly like a
ceiling with no effect, and the difference is which queue the consumer binds to.

That second queue is `BufferedBroadcastController`, sized by `bufferedBytes` and therefore
unbounded for direct objects too. It is **B-217**, filed with these numbers: the bound there
would be per-CONNECTION, a different field with a different meaning, and inventing it inside
this round is the mistake B-209 and B-128 both record.

## Canary

Two, one per half of a bound-and-release pair.

```
A. the event dimension dropped from `admit`

   WITNESS a paused consumer cannot be queued past the depth
     Expected: <Instance of 'RpcStatusException'> with `statusCode`: <8>
       Actual: <null>
   Only the witness failed; all three guards stayed green.

B. the event charge never released

   GUARD a consumer that keeps up receives everything
     Expected: <50>
       Actual: <3>
   and the release guard with it. The WITNESS still passed — a bound that never
   frees still refuses, which is exactly why the two halves need separate arms.
```

Canary B is the one worth having: it fails the arms about normal traffic while leaving the
witness green, so a fix that bounded and never released would have looked correct.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          REUSE compliant
```

`format:check` failed once on the two new test files and was re-run green.

**The ledger's own unit test would not compile** — eight constructions without the new required
argument. They were updated to pass a deliberately huge `limitEvents` so each keeps measuring
the byte rule it was written for, and the event dimension got its own group of five cases
instead of being folded into theirs.

## Not fixed

**`P-135` cannot see this fix and was not expected to.** It counts what the PRODUCER generated,
and this is a residency bound on the receiver: the paused zero-copy arm still reads 314569
produced, because nothing paces the producer. Those are two different questions on one path and
the round did not conflate them.

**Nothing bounds the connection-wide buffer.** B-217, with the 355 MiB reading.

**The isolate transport is unmeasured here**, and the lead settles it by reading rather than
measurement: `SendPort.send` deep-copies all but deeply-immutable values, so a direct object
there has real bytes and the byte ledger already bounds it. The event ceiling applies anyway and
costs it nothing.

## Links

Lead `../backlog/archive/B-106-zero-copy-has-no-backpressure.md` — closed by this round.
Lead `../backlog/B-217-the-connection-wide-buffer-has-no-depth.md` — new.
Bench `../probes/P-178-minting-against-holding.md` — reused; its consumer moved to the per-stream
path and a bounded arm added.
Round `549-a-pointer-or-a-payload.md` — the measurement this decision rests on.
Round `536-the-release-that-freed-only-bookkeeping.md` — the bound-without-release shape canary B
reproduces.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [550]`.
