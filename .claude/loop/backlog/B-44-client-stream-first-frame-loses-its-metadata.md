---
status: open
round: 366
commit: bb8548939524ee67a53dcc5339d15f772e3f032e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/rpc/streams/client/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: bench — no repro exists outside a browser; the only witness today is a consumer's production log
---

# B-44 — a client-stream message reaches the responder with its fields empty (dart2js/WS)

A consumer (rhyolite, Obsidian plugin, dart2js + browser WebSocket) uploads
blobs over a client-stream whose first message per blob carries the identity of
what follows (`blobId`, `vaultId`, `totalLength`) and whose later messages carry
payload only. In production **that first message arrives with those fields
null**, and the handler cannot tell which blob it opened.

The consumer's server logs it as `Bad state: First chunk must carry blobId and
vaultId`: **86 occurrences in 3.6 days** across two replicas, on a service
carrying otherwise ordinary traffic. Same symptom recorded by that project since
2026-06-20, on the VM never — `rpc_dart_websocket`'s own native test
("client stream aggregates uploaded messages") passes, and the consumer's Dart
CLI client on `dart:io` WebSocket does not reproduce it.

The same project also carries a server-side workaround for a second observation
on this path: **each WS message delivered twice** on a cold connect. Its
deduplicator has been in place since 2026-05 and is what makes the doubling
survivable there.

## Why it is the library's

Nothing above is application logic. A client-stream message is serialized by
the caller and decoded by the responder; a field that was set when it went in
and is null when it comes out is either a lost/reordered frame or a decode
against the wrong bytes. A consumer cannot fix that, and the cost is not
cosmetic: the identity-carrying message is exactly the one that must not be
lost, so the failure mode is a stream whose remaining frames belong to nobody.

## What a bench needs

- A dart2js/browser WebSocket peer. Both known observations (the doubling and
  the empty fields) are browser-only, so the ordinary `dart test` gate cannot
  see either.
- A client-stream of N messages where every field is a checkable function of
  the index, so a lost, reordered or duplicated frame is distinguishable from a
  decoded-wrong one. The distinction is the whole question and the consumer's
  logs cannot make it: their handler only records that the first field is null.
- A cold connect per run. The consumer's account says "the first ~2 streams
  after a cold connect", though their 2026-09 logs show failures minutes into
  a session, so that scoping is itself unverified.

## What the 2026-09-15 session eliminated

The bench exists now — [P-51](../probes/P-51-browser-client-stream-delivery.md),
plus `client_stream_delivery_test.dart` for the two cheaper arms — and it did
NOT reproduce. Four candidates are out:

1. **The VM and the core pipeline.** 50 small messages, 8 × 256 KiB, a handler
   that stalls 300 ms, four concurrent calls: no loss. A window bound small
   enough to matter fails LOUDLY (`RpcStatusException(14)`), which is the
   opposite of the symptom.
2. **dart2js semantics.** The same shapes over an in-memory WS pair, compiled
   and run in Chrome: clean.
3. **The real browser WebSocket.** 36 calls against a real dart:io server,
   including four concurrent 256 KiB calls, twenty sequential ones, and ten COLD
   connections: every message once, in order.
4. **The lenient send after close.** `RpcChannelTransport` returns quietly where
   five siblings throw, and it really does drop the bytes — but the CALL still
   fails UNAVAILABLE off the read side, so it cannot produce a short answer.
   Measured, fix written, reverted: [C-38](../checked/C-38-the-lenient-send-is-not-a-lost-message.md).

Also corrected: `7a3c66d5` ("refuse work while a reconnect is in flight") looked
like the answer — its own commit message describes sends "accepted and dropped
silently" — and it is NOT this consumer's path. They reconnect through
`RpcClientConnection`, whose proxy THROWS `transport not connected`, and that
message appears in their logs. The fix covers `RpcWebSocketCallerTransport`'s own
reconnect, which they do not use.

## Remaining suspects, ranked

- **The pinned ref.** They run `55159adf` (6.0.0) on both sides; the bench ran
  HEAD, 26 commits later. Cheapest next step by a wide margin: pin both sides at
  `55159adf` and re-run P-51.
- **The network path.** Production is `wss://` through a Caddy ingress; the
  bench is a bare local socket. A proxy that splits or coalesces frames is the
  kind of difference that would not show anywhere else.
- **Electron's renderer**, not plain Chrome.
- **Payload size**: theirs are ~1 MiB encrypted blobs chunked to 256 KiB, so a
  call carries several MiB rather than 2.

## Candidate to check first

`e4238948` ("a torn-down stream was resurrected by its own body frame", in
6.0.0) tightened `_processResponderMessage`: a frame for a stream with no state
is now ignored unless it also carries METADATA. That is the one change in this
window that turns a mis-stated frame into a **silently dropped** one, and the
consumer's onset (2026-09-12, the morning after they took 6.0.0) is consistent
with it — but so is their own retry breaking in the same bump, which IS proven.
Treat as a lead to measure, not an explanation: an ablation on the doubled-frame
path is what would separate them.

## Not established

That 6.0.0 made the loss more frequent. The consumer's server pods hold no
logs from before the bump, so there is no baseline on either side.

## Owner decision

—
