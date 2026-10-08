---
round: 719
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-17
bench: P-235 — new
commit: yes
release: changelog
---

# Round 719 — tiny messages are weighed

## Target

Round 715's own fix, re-measured (RPC-15's habit, RPC-17's question: what does
the limit COUNT). 715 lifted the per-stream depth bound for HTTP/2 request
queues to 2^30 and wrote "the 4 MiB byte bound stays". It never measured what
a queue of tiny messages retains against that bound.

## Hypothesis

The responder's budget charges a queued message its `bufferedBytes`. For a
2-byte payload that is 2 bytes, while the message retains about a hundred.
With the depth bound lifted, the connection total (64 MiB of payload) admits
tens of millions of messages, and memory grows with the stream count.

## Before

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r719_tiny_messages_past_the_byte_bound.dart`.
Client-stream calls of `'x'` (2 payload bytes) to handlers that do not read;
one process, so RSS includes the caller.

```
  arm                               streams  accepted   rssDelta
  drains (control)                     1     1000000    -14 MiB
  parked                               1      422002    +71 MiB
  parked                               8     3407690   +413 MiB
  parked                              32    13631616   +968 MiB
  parked, depth bound restored (pre-715)  8     3407046    -98 MiB
```

Each stream is refused only by the transport's own per-stream window (4 MiB of
wire bytes, ~422k messages). Nothing bounds the sum across streams, and
`maxActiveStreams` defaults to 4096.

## Mechanism

`RpcResponderBufferBudget` charged `message.bufferedBytes`, which is the
payload length. With `streamEvents` at 2^30, nothing counted the per-message
retention, so the connection total stood at 64 MiB of payload, about 33M
two-byte messages.

## Fix

Where the depth bound is lifted (`IRpcNoMessageCredit`), the budget charges
each payload or direct message `bufferedBytes + 128` (`perMessageBytes`, via
`weigh()`). The same function runs at take and give. Other transports keep
their depth bound and a zero charge. The policy, the marker's doc and the
skill table say so.

## After

```
  parked                               8     3407386    -30 MiB
  small_uploads_are_bounded_by_bytes_test (715's honest peer)   passes
```

## Canary

`perMessageBytes` forced to 0: `tiny_messages_are_weighed_test` fails with
"the queue passed the connection total without a refusal" (`Actual: []`).

## The verdict questions

1. Yes. The case and the control differ only by the handler draining. The
   pre-715 arm differs only by the marker check.
2. Yes: +413 against -98 / -30 MiB.
3. RSS of the server process, which also holds the caller. The drains arm
   reads -14, so the caller side retains nothing.
4. Not zero.
5. Quoted: "the queue passed the connection total without a refusal".
6. One mechanism.
7. A trade for an honest h2 peer: past the connection total of 64 MiB, its
   queue is refused at about 490k tiny messages held, where before it was
   about 33M. 715's slow-handler witness (30 000 messages) is unaffected.
8. None.
A1. Server policy and caller policy are separate objects. The witness narrows
    the server's connection total.
A2. Volume.
L1. The refusal names the budget ("buffered too much without consuming it");
    the transport's own per-stream window does not fire at 50k messages.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`, `check:skills`.
Suites: core 2099, rpc_dart_http2 303.

## Not fixed

The overhead constant is one number for every message shape. It was measured
at 75-176 bytes retained per message across the arms.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [..., 719]`.
New bench `../probes/P-235-tiny-messages-against-the-byte-bound.md`.
Round `715-h2-uploads-bounded-by-bytes.md` is the fix this re-measures.
