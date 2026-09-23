---
status: closed (round 383)
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

## Round 383, second pass — the candidate is IN their build, and its exact shape

`git merge-base --is-ancestor e4238948 55159adf` → **true**. The commit this
record named as "candidate to check first" is in the consumer's 6.0.0, so it
cannot be excluded on version grounds.

What it changed, read from the diff rather than the message:

```
-      if (message.methodPath == null) {
+      if (message.methodPath == null || message.metadata == null) {
```

A frame for a stream in `_respClosedStreams` used to be admitted whenever it
carried a methodPath; now it must carry metadata as well. **A DATA frame has no
metadata**, so a first payload frame that would previously have revived a
released id is now dropped silently. That is exactly the direction B-44's
symptom needs, and the commit's own reasoning never considers it — it was aimed
at the HTTP/1.1 responder tagging DATA frames with a method path, which is the
same mechanism used the other way.

**What has to be true for it to fire**, and this is where it is still open: the
stream's state must be GONE while the call is still live, because the guard only
runs when `_respStreams[id] == null`. Two routes were checked and one survives:

- *id reuse* — ruled out. `RpcStreamIdManager.generateId()` restarts only when
  the 2^31 range is exhausted with nothing in flight, so a connection does not
  come back round.
- *half-open reclaim* — **not ruled out**. `_armHalfOpenReclaim` tears a stream
  down after `halfOpenStreamTimeout` (60 s default) if no request message has
  arrived, and puts its id in `_respClosedStreams`. A caller that opens the
  upload and then takes longer than that before its first chunk — hashing a
  large file, a slow link, a browser tab throttled in the background — would
  have its opening frame accepted, its state reclaimed, and its first DATA frame
  dropped by the new guard.

That last one fits the consumer's environment (an Obsidian plugin, where the tab
can be backgrounded) and fits "the first ~2 streams after a cold connect" less
well. It is a hypothesis with a stated trigger, not a measurement.

**Measured, and the route is closed.** 5 chunks with the id only on the first,
`halfOpenStreamTimeout` varied:

```
arm                             result
fast start, 300ms window        first ok (index=0) | handler got 5
stall 600ms, 300ms window       first ok (index=0) | handler got 5
stall 600ms, 30s window         first ok (index=0) | handler got 5
```

The stall arm behaves exactly like the fast one, and the generous-window control
confirms the timeout was the variable rather than the stall.

**Why it cannot fire, and this is the useful part**: a client-stream has no
"opened and silent" window at all. `CallProcessor` sends its initial metadata
from `_transmitRequest` — i.e. with the FIRST message — or from
`_queueInitialMetadataIfUnsent` at the half-close. So the server learns the
stream exists at the same moment the first chunk arrives; there is no interval
in which the state exists, is half-open, and has no payload. The reclaim timer
is armed and cancelled in the same breath.

Bidirectional is the shape that DOES have that window, and only since round 373
announced the call in the caller's constructor. So if this route ever becomes
reachable it will be there, not here — worth remembering, and not this record's
defect.

Probe: `packages/core/rpc_dart/.dart_tool/probe/first_chunk_after_half_open_reclaim.dart`.

## Round 383, third pass — the consumer's own ref, and dart2js

Two more axes, both of which this record named and neither of which had been
run.

**On `55159adf` itself**, in a worktree, with the consumer's shape — 17 chunks,
ids on the first only — on one long-lived connection:

```
sequential 40 uploads:  calls=40 badFirst=0 short=0
concurrent 20 uploads:  calls=20 badFirst=0 short=0
```

So the pinned ref is not it. The version gap that looked like the cheapest
remaining explanation buys nothing.

**On dart2js**, which is the axis this record says the defect is exclusive to
(*"on the VM never"*) and which every bench so far had missed — the core
pipeline over `RpcChannelTransport.pair()`, compiled and run under node:

```
25 sequential uploads:  badFirst=0 short=0
12 concurrent uploads:  badFirst=0 short=0
```

Pinned by `test/streams/b44_first_chunk_on_js_test.dart`, deliberately
transport-free so that a failure there would be the COMPILER's rather than the
socket's.

## Where this leaves it

Every axis reachable from this repository is now measured and clean:

| axis | verdict | where |
| --- | --- | --- |
| VM + core pipeline | clean | P-51 |
| dart2js semantics | clean | P-51, and round 383 again |
| real browser WebSocket | clean | P-51 |
| lenient send after close | not the cause | C-38 |
| wire SLICING | clean | P-71 |
| stream-id reuse | unreachable | round 383 |
| half-open reclaim | cannot fire for client-stream | round 383 |
| the consumer's pinned ref | clean | round 383 |
| many uploads on one connection | clean | round 383 |
| concurrent uploads | clean | round 383 |

**The library reproduces nothing.** That is not the same as "the library is
innocent" — an unreproduced defect stays a defect — but it does move the next
step off this repository. What is left is the consumer's environment: Electron's
renderer rather than plain Chrome, and the `wss://` ingress COALESCING writes
rather than splitting them, which is the one toxic not tried.

## Closed — round 383, by the owner: not reproducible anywhere

Ten axes measured, all clean (table above), including wire COALESCING, which was
the last one reachable here. The owner's call was to stop, and the search was
genuinely out of moves.

**What the round left behind instead.** The reason this took six rounds and
still has no cause is that the failure is SILENT: a request vanishing between
the peer and the handler lets the caller be told the call succeeded over a
sequence the handler never saw. The pipeline now compares what it accepted with
what it delivered, as the call ends, and says so at `error`:

```
Request messages LOST for Svc.put [streamId: 1]: the pipeline accepted 17
and the handler was given 2 — 15 never arrived (dropped: 0)
```

So if this is the library's, the consumer's next occurrence names itself. If
nothing ever appears in their logs, that is evidence too — and it is the first
time either statement can be made.

## What would actually settle it, and it is on their side

The pipeline already has the instrument: `_processResponderMessage` logs every
inbound frame at `debug` —

```
inbound [streamId: N] method=… metadata=true/false payload=… endOfStream=…
```

Turning that on in production for one upload answers the question this record
opens with and cannot answer from here: whether the first message ARRIVES and
is decoded wrong, or never arrives. Round 375's note applies — the caller knows
what it sent, only the peer knows what was read — so the two ends have to be
compared, and only they can do it.

## Not established

That 6.0.0 made the loss more frequent. The consumer's server pods hold no
logs from before the bump, so there is no baseline on either side.

## Owner decision

—
