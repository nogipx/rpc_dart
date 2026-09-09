---
round: 236
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http, rpc_dart_http2]
lens: RPC-17
bench: P-15 — new
budget: probes 2/3, canaries 1/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 7 of 7
commit: yes
---

# Round 236 — the bound that counted the wrong thing

## Target

RPC-17, never applied. `next` named RPC-16 instead, which was wrong and the
reason is bookkeeping: RPC-16 was swept clean only last round, but I had filed
the five imported lenses under a heading it led, so the rank pointed back at it.
Moved RPC-16 down to "productive lately" — where a confirmed, just-swept lens
belongs — and `next` then named RPC-17 on its own.

## Hypothesis

RPC-17's second clause: **which DIMENSION does each nearby limit measure** —
count, per-item size, duration — and does any of them measure TOTAL BYTES? The
class lives in the gap.

## Before

The detector's list is every inbound buffering site. The fixed instances
(`RpcHttpCallerTransport`, `_onData`, `bufferPreMethod`, permessage-deflate, the
gzip codec) all still hold. The site nobody had read this way is
`BufferedBroadcastController`, which every transport puts on its inbound path —
six construction sites, all on the default.

Its own doc says the queue "never grows past `maxPendingEvents`... so memory
stays bounded instead of growing without limit". **The bound counts EVENTS.
Nothing counts bytes**, and the neighbour, `maxMessageLengthBytes`, bounds ONE
message at 16 MiB by default. 4096 x 16 MiB = **64 GiB admitted**.

Measured with the queue's own counter, 4096 messages, payload varied:

```
   16 KiB each   pending=4096   retained   64 MiB
   64 KiB each   pending=4096   retained  256 MiB
  256 KiB each   pending=4096   retained 1024 MiB
```

The count never moves; the bytes scale linearly. Through a real transport, arms
differing only by whether anything is subscribed to `incomingMessages`:

```
  tx  listener      delivered=4096   RSS   +2 MiB
  tx  NO listener   delivered=0      RSS +549 MiB
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/pending_queue_counts_events.dart`
(bench `../probes/P-15-pending-queue-dimension.md`).

## Mechanism

The queue exists to bridge the window between a transport consuming the
connection and the pipeline subscribing. It is bounded in the dimension that is
easy to count and unbounded in the one that costs memory. Reachable wherever
that window is not instantaneous — an app that builds a transport and wires its
endpoint a few awaits later, or a consumer that cancels and does not re-listen,
since the class buffers between listeners by design.

Fixed in the controller, where the "memory stays bounded" claim lives: a
`maxPendingBytes` (16 MiB, generous for a handful of leading frames) weighed by
an optional `sizeOf`, since a generic `<T>` cannot know how to weigh its items.
`RpcTransportMessage.bufferedBytes` gives the rule one home, and the six sites
pass it. **The byte bound reuses the count bound's existing overflow path** —
deliver survivors, raise, close — rather than inventing a second failure mode.

## After

Same probe, same arms: **+549 MiB -> +58 MiB**, control unchanged at +2 MiB.

## Canary

The byte half of the condition removed in place. **3 witnesses failed, all 4
guards passed**: `Expected: <16>  Actual: <200>`, `Expected: <4>  Actual:
<200>`, `Expected: <2>  Actual: <50>`. Restored, 7/7 green. The guards matter
here: one pins that a caller with NO sizer keeps exactly the old count-only
behaviour, and one pins that the leading frames a cold connection needs still
arrive in order — the thing the queue exists for.

## Gate

`melos run analyze` SUCCESS (it caught an `unnecessary_import` in the new test
first). `melos run test:unit --no-select` SUCCESS workspace-wide.
`melos run format:check` SUCCESS. `melos run license:check` REUSE compliant.

## Not fixed

**The byte bound is inert for a caller that supplies no `sizeOf`**, which is
every third-party user of the class. The alternative was to make the parameter
required, a breaking change to a public core type, for a class whose only
in-repo users are the six sites now wired. Documented on the constructor rather
than silently half-applied.

**16 MiB is a chosen number, not a measured one.** It is one message's worth at
the policy default, and the queue's purpose is a handful of leading frames, so
it is generous for the legitimate case — but no probe established where a
legitimate cold connection actually peaks. A deployment that legitimately buffers
more will now hit the overflow path, which closes the connection.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [236]`, and
this is its first application in the journal.
Bench `../probes/P-15-pending-queue-dimension.md` — new, validated by its
control, and rebuilt once for the two RSS traps recorded there.
Round `234` — the curate pass after it imported this lens from private memory.
