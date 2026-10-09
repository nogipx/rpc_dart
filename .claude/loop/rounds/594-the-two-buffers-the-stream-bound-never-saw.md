---
round: 594
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-211 — new
budget: probes 2/5, canaries 0/5
commit: yes
release: changelog
severity: S1
---

# Round 594 — the two buffers the stream bound never saw

## Target

`B-138`, continued from round 593, which named the next step exactly: attach a
responder with a parked handler, so a peer-minted stream is dispatched, and read
what bounds a flood from a peer that ignores flow control. Taken first because it
is the only lead `next` marks as an unfinished continuation in the rpc_dart and
websocket scope, and 593 had already paid for the dead ends.

Scope, set before the fix: every responder-side buffer a peer's REQUEST frames can
land in, per shape. Five paths were found:

```
path                               shape                  bound before
per-stream controller (transport)  bidi, server-stream    _admitToStreamBuffer
pipeline-fed request sink          client-stream          none
pre-bind list                      unary, while running   none
pre-bind list                      others, until bind     none (window is microtasks)
pre-method list                    any, before metadata   _respMaxPreMethodBytes
```

## Hypothesis

`_pipelineFedRequestStream` feeds a client-stream handler through a plain
`StreamController`, so the transport's per-stream bound never sees it. Against a
peer that ignores grants, a handler that stops reading would hold everything the
peer sends. Refuted if the client-stream arm stays near the bidi arm.

## Before

```
                                            PULLED    RETAINED          resident
CONTROL  client-stream, peer honours window    258      257  (~4 MiB)    +10 MiB
WITNESS  client-stream, peer ignores window  20000    19999  (~312 MiB) +304 MiB
SIBLING  bidi, peer ignores window           20000     1023  (~16 MiB)   +28 MiB
```

20000 frames of 16 KiB, handler reads one message and parks; responder on the
default policy, peer with its windows off (separate policy objects). RETAINED is
what the handler drains after it is released with the producer stopped, so it
counts what the responder side held. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b138_a_flood_into_a_stalled_handler.dart`
(one arm per process: `control`, `witness`, `bidi`).

The sweep found a second instance. A unary state is never marked bound, so every
data frame a peer sends while the handler runs goes to `_preBindBufferedMessages`:

```
sent after the request   resident
    0                    -40 MiB  (noise)
   78 MiB                +51 MiB
  156 MiB               +117 MiB
  312 MiB               +313 MiB
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b138_frames_after_a_unary_request.dart`.

## Mechanism

The per-stream bound lives in the transport and applies to what it routes into a
per-stream controller. Two shapes take their frames from the pipeline instead:
client-stream (by design, `_pipelineFedRequestStream`) and unary (its state is
never bound, so `storePayload` keeps appending). Flow control is the only other
limit on that path, and it is a send-side protocol a foreign peer can ignore.

## After

```
                                            PULLED    RETAINED          call
CONTROL  client-stream, peer honours window    258      257  (~4 MiB)    -
WITNESS  client-stream, peer ignores window  20000     1023  (~16 MiB)   RESOURCE_EXHAUSTED
unary, 312 MiB after the request                                         +57 MiB, refused
```

The fix applies the policy's two per-stream ceilings
(`effectiveMaxBufferedBytes`, `maxBufferedMessagesPerStream`) to both buffers:

- the client-stream sink charges on `pushRequest` and releases as the handler
  takes each message; over the ceiling it fails the request stream with
  RESOURCE_EXHAUSTED and drops the rest;
- `storePayload` charges the pre-bind lists and the `take*` methods release them;
  over the ceiling the pipeline answers RESOURCE_EXHAUSTED and cleans up, the
  same answer as the pre-method refusal next to it.

A regression found while writing the release witness and fixed in this round: a
unary waiting for its next fragment was STILL appending every fragment to the
pre-bind list after feeding it, so the new bound would have refused a request
split into more than 1024 pieces. That branch now runs before `storePayload`.
By reading, not measured: before this round those copies were retained for the
life of the call.

## Canary

Six switches, each first attempt; the other tests stayed green under each.

1. Sink bound off: `stalled client-stream handler holds no more than the message
   bound` and `nor more than the byte bound` fail with `Expected: <= 64, Actual:
   <1999>`.
2. Sink BYTE half off only: only the byte test fails, `Actual: <1024>` (the event
   ceiling caught it instead).
3. Sink release off: `CONTROL: a handler that keeps reading` fails with
   `RpcStatusException(8): Stream 1 buffered more than 64 messages`.
4. Pre-bind bound off: `frames after a unary request are bounded` fails with
   `Expected: '8', Actual: <null>`.
5. Pre-bind release off: `exactly the limit fits` fails with `Expected: '0',
   Actual: '8'` — the request's charge left behind refuses one frame early. Its
   neighbour `one more is refused` is the other side of the boundary.
6. Fragment branch back after `storePayload`: `a unary request split finer than
   the limit is still answered` fails with `Expected: '0', Actual: '8'`, `65
   fragments`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages, rpc_dart
+1884, rpc_dart_websocket +242), `melos run format:check`, `melos run
license:check` — green. Re-run after the last change (fragment reordering):
core analyze and format green, `test:unit` green across 15 packages with rpc_dart
at +1887. The new test and `unary_tolerates_a_fragmented_frame_test` pass on
`-p node`.

One existing test changed outcome and was not edited:
`unary_tolerates_a_fragmented_frame_test` "a REFUSED frame is not reported as a
truncated one" — on that arm the pre-bind bound now fires before the parser, with
the same RESOURCE_EXHAUSTED. Its requirement that the message name the limit
(`max:`) is met by the new message.

## Not fixed

- The CONNECTION total. Every per-stream bound multiplies by the stream ceiling:
  `maxActiveStreams` 4096 × 16 MiB is what a peer ignoring grants can still park
  on one connection. Arithmetic, not measured. This is what remains of B-138.
- `IRpcChannel`'s own example, the isolate and wasm channels (RPC-08 shape, named
  by round 534) — still unswept.
- B-217's connection-wide `_incoming` buffer is a separate lead and untouched.
- The pre-bind window for bidi and server-stream (first frame to bind) is now
  bounded too, but nothing measured it: it is a few microtasks wide.

## Links

Lead `../backlog/B-138-the-websocket-channel-has-no-read-backpressure.md` — stays
open, narrowed to the connection total.
Bench `../probes/P-211-a-flood-into-a-stalled-handler.md` — new.
Bench `../probes/P-212-frames-after-a-unary-request.md` — new.
Bench `../probes/P-210-what-the-transport-pulls-from-a-flooding-peer.md` — stays
broken; P-211 is its repair.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [594]`.
Test `packages/core/rpc_dart/test/transports/client_stream_sink_is_bounded_test.dart`.
