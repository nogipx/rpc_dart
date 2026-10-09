---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b176_reconnect_strands.dart
round: 572
commit: 09aa8e60
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-193 — what are in-flight consumers told at a teardown?

## Why it exists

B-176's own witness, built as specified: three in-flight server streams, a teardown, time to error
per call. A hang has no number of its own, so the measurement is the absence — `STILL WAITING`
against a generous three-second settle, where a call that fails fast does so in ~10 ms.

## The harness

A raw `http2.ServerTransportConnection` that sends one item per stream and then holds it open
forever, so every call is genuinely in flight when the teardown lands. Each consumer records what
it was told and when: an error with its status, a clean end, or nothing.

The same arm drives BOTH teardowns — `reconnect()` and `close()` — because the lead names only the
first and a second site is a guess until it is measured.

## The numbers (round 572)

Before:

```
reconnect()   Unhandled exception: Concurrent modification during iteration:
              _Map len:2.    ... _reconnectOnce :1946

with the iteration fixed:
reconnect()   call 0  STILL WAITING
              call 1  error after 10ms: status 14
              call 2  error after 11ms: status 14
              maps after  1 controllers

close()       call 0  error after 54ms: status 14
              call 1  error after 54ms: status 13
              call 2  error after 54ms: status 13
```

After:

```
reconnect()   call 0, 1, 2  error after 24ms: status 14    0 controllers
close()       call 0, 1, 2  error after 62ms: status 14
```

## Measures

Per consumer: whether it was told anything, what status, and how long after the teardown. Plus the
transport's leftover `streamControllers`, which is the only side that can see the entry a stranded
call leaves behind.

## Control

**`close()` is the control, and it is a measured NEGATIVE**: it strands nobody, so the stranding
belongs to `reconnect()`'s ordering rather than to teardowns in general or to the rig. It also
caught something else — a MIXED `14/13/13` for one event, which is round 571's status split
answering for a hang-up this side initiated.

**The three-second settle is what makes `STILL WAITING` mean something.** The calls that do fail
take ~10 ms, so two orders of magnitude separate the two outcomes.

## What it establishes, and what it does not

Establishes that `reconnect()` threw `ConcurrentModificationError` with two or more streams in
flight, that once that was fixed the first consumer was left waiting with a controller behind it,
and that `close()` does neither.

Does NOT separate `closeAll`'s `error:` argument from the call itself. Disabling only the argument
still read three errors, because closing the controller and the terminate error race; removing the
call is what shows the stranding.

Does NOT chart what the crash leaves behind — a transport with every map cleared, `_disconnected`
true and no connection. The round fixed the crash rather than measuring its aftermath.

Does NOT witness the `_fcRefused` / `_resetStreams` carry-over: `fcOutstanding` read 0 in every arm.

## Reading

rpc_dart_http2 — three in-flight server streams, then a teardown, recording
per consumer what it was told and when. **A hang has no number, so the
measurement is the absence**: `STILL WAITING` against a three-second settle
where the calls that do fail take ~10 ms. Drives BOTH teardowns, which is how
`close()` came out a measured NEGATIVE — and how its MIXED `14/13/13` for one
event surfaced. Reads leftover `streamControllers` beside the outcomes. Does
NOT separate `closeAll`'s `error:` argument from the call: disabling only the
argument still read three errors, because closing the controller and the
terminate error race
