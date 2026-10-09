---
round: 710
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-17
bench: none — `.dart_tool/probe/parity_matrix.dart`, group 7 (volume and pace), five transports
commit: yes
release: changelog
severity: S2
---

# Round 710 — the window fits the buffer

## Target

B-258, found by the matrix the owner asked for after round 709: a sender
inside its byte window overruns the receiver's byte queue bound when
`maxMessageLengthBytes` is below the window.

## Hypothesis

The queue bound is `maxMessageLengthBytes + 5`; the sender may have the 4 MiB
window in flight. Any reader slower than the producer fails the stream.

## Before

```
7.ss-60k-items-x50-slow-reader (maxMessageLengthBytes 64 KiB, 20 ms per item)
  memory, isolate, http2   all
  websocket                ERR at 3/50  buffered more than 65541 bytes
```

Same at `5170cd3c`, so not caused by round 709.

## Mechanism

As hypothesised. Two neighbours of the round-709 seed rule showed up in the
fix: the first BYTE grant, and the first CONNECTION grant, were added to the
initial send window instead of replacing it, so the first round trip could
carry the seed on top of the advertised window.

## Fix

- `RpcSecurityPolicy.effectiveStreamBufferBytes`: `maxBufferedBytes` when set,
  else window + one framed message + `maxMetadataBytes` (window off: message
  + 5). Used by the transport's per-stream ledger and the responder's request
  budget. Frame reassembly keeps `effectiveMaxBufferedBytes`.
- `RpcSecurityPolicy.advertisedWindowBytes`: the window, or less when an
  explicit buffer cannot hold it plus one message and metadata; at least 1.
  The receiver advertises it and batches grants against it.
- The first per-stream byte grant and the first connection grant replace the
  initial send window, less what was sent under it.

Two test premises depended on the seed being added: `parked_send_after_finish`
let three 4000-byte frames through a 4096 window; now two.
`the_ending_waits_inside_the_waking_turn` treated its first grant as an
increment; it now sends the advertisement first, as a live peer does.

## After

Group 7 on all five transports: memory, isolate, websocket, http2 deliver
every scenario. An explicit `maxBufferedBytes: 64 KiB + 5` delivers 30/30 at
one message per round trip.

## Canary

Ledger back on `effectiveMaxBufferedBytes`: the witness fails with "buffered
more than 65541 bytes". Advertised window back to the full window: the
explicit-buffer test fails the same way.

## The verdict questions

1. Yes: before on `5170cd3c` and HEAD.
2. Yes: websocket and the shared core layer.
3. Yes: items delivered.
4. Not zero-valued.
5. Quoted.
6. One cause plus the two seed neighbours, each with its own unit test.
7. A trade, asked: per-stream memory with a small message limit grows to the
   window, which flow control already permits; owner chose it.
8. Two premises changed, stated above.

## Gate

`analyze`, `format:check`, `check:skills`, `test:unit`, `test:wasm`,
`test:web`.

## Not fixed

- http1 fails every stream past 1024 messages (`maxMessagesPerChunk`) and every
  response past `maxBufferedBytes`. Documented in its README as unary-only;
  left.
- The matrix runs on the VM only. dart2js and dart2wasm columns are the next
  step.

## Links

Lead `../backlog/B-258-the-window-outgrows-the-stream-buffer.md` closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` -- `applied: [..., 710]`.
