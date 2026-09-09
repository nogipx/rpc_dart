---
status: open
round: 214
commit: 359c79ad
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: cost — round 214 swept the other half of RPC-05's detector and this one needs its own bench, which does not exist yet
---

# B-16 — is the pre-method byte budget released on every teardown path?

The last charge/release pair in `RpcSecurityPolicy` that round 214's sweep did
not reach. `_respPreMethodBytes` is a PER-CONNECTION byte budget, charged when a
DATA frame arrives for a stream whose method is not yet known, released by
`_releasePreMethodBytes`. Its ceiling is `maxMessageLengthBytes`.

It is the highest-severity pair left, because its own comment records exactly
what it exists to stop — a raw client pushing 4 KiB DATA frames at a stream id
it never opened with metadata:

    pushed 250.7 MiB  ->  server RSS +495.2 MiB   (8113 B per 4 KiB frame)

versus 28.8 MiB for the same volume at a stream the server had already answered.
No rpc_dart client is needed: three hand-built frames on a plain WebSocket do
it. If the RELEASE leaks, the budget fills with bytes from streams that are long
gone and the connection stops accepting the reorder window the buffer exists to
cover — and, worse, a leak would be per connection, so it is reachable by
anyone.

## The bench to build

Behavioural, like P-06 — do not read the private counter:

- `RpcChannelTransport.pair()` with `maxMessageLengthBytes` set small, say
  256 KiB, and `halfOpenStreamTimeout` set LONG so that time-based reclaim is
  not what cleans up. That last part matters: the comment says the timeout was
  the only thing bounding this before, so leaving it short would hide a leak.
- Park half the budget on a fresh stream by `createStream()` then `sendMessage`
  with NO metadata first, so the method is unknown and the bytes are buffered.
- Tear that stream down, once per mode: `finishSending` + `releaseStreamId`, a
  terminal frame from the peer, and the half-open reclaim.
- Repeat six times, then park half the budget once more and check it is still
  admitted rather than refused with RESOURCE_EXHAUSTED.

Control: the ablation. Make `_releasePreMethodBytes` a no-op and the third
iteration must already be refused — without that the bench has not been shown to
see the defect, which is the trap round 210 recorded and round 214 avoided.

## Owner decision

—
