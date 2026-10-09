---
refines: U-08
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
applies: a server-side entry point has rejection exits that run before the request is registered
breaks: DoS.
applied: [272, 274, 275, 276, 277, 283, 284, 287, 288, 361, 395, 397, 399, 400, 532, 591, 604, 610, 624, 662, 664, 671, 725, 790, 792, 793, 794, 795]
status: confirmed (round 397)
rank: 9
---

# RPC-22 — The path a peer reaches without being accepted

## Shape

Every guard on the accepted path — a deadline, a counter, a cap — has to be
asked of the REFUSAL path separately. That path is reachable by anyone (no valid
content-type, method, credentials or stream), and nobody looks there because "we
already said no" reads like the end of the story. U-08 is one limit applied to
BOTH the body and the diagnosis of why there is no body; this is the reverse: a
limit applied to the body and to nothing else. On connection-oriented transports
there is also a stage BEFORE any rejection: accepted, not yet speaking.

## Detector

Enumerate the rejection EXITS of each server-side entry point, and for each ask
which of the accept path's guards it inherits. In `rpc_dart_http` that is
`_reject`'s five callers — transport closed (503), not POST (405), at the stream
ceiling (503), wrong content-type (415), bad method path or metadata (400) —
every one reached before `_pending[streamId]` exists, so before any counter and
deadline. Then drive EACH exit: two refusal exits in one file are two
measurements.

Then: does the rejection still do WORK — draining a body, building a page,
logging, hashing? Work on a path with no admission control is work an
unauthenticated peer commands directly. Ask what it WRITES to the operator's log
too. Grep the knob, not the intent.

## Ask

Which is cheaper for an attacker — being accepted, or being refused? If the
answer is "refused", the refusal path is the attack surface.

Round 399's second clause: cheaper for the attacker AND dearer for the server.
Ask both sides, or a cheap refusal that is also a cheap ANSWER reads as a
finding. Round 400's third: who pays for the ANSWER — a refusal is a write, so
does a peer that reads nothing make the server hold it? And before pricing a
refusal, what did the SERVER spend to reach the decision?

## Evidence

- **Round 272** — `RpcHttpResponderTransport._reject` drained the body with no
  deadline: `text/plain` 0 of 16 answered vs 16 of 16 408 for `application/grpc`,
  `pendingRequests` 0 in both. A timeout written on the happy path is a local
  variable, not a policy (`bodyReadTimeout` had one call site). The fix cancels
  the subscription rather than timing out the future.
  Bench `../probes/P-23-the-refusal-path-has-no-deadline.md`; round
  `../rounds/272-refused-is-cheaper-than-accepted.md`.
- **Round 274** — `RpcHttp2Server._handleConnection` built 200 endpoints and
  contracts for 200 silent sockets. Every PER-CONNECTION limit
  (`maxActiveStreams`, `maxConcurrentHandlers`, `halfOpenStreamTimeout`) is
  downstream of a peer that has not opened anything; ask where the FIRST counter
  sits. Deferred as B-27. Bench `../probes/P-25-a-tcp-syn-builds-an-endpoint.md`,
  `../rounds/274-work-before-the-peer-speaks.md`.
- **Round 275** — the owner chose the deadline: `prefaceTimeout` (30s, disarmed
  by the 24-octet preface; 0 bytes -> 0 endpoints, 24 bytes -> 200). Price a
  pre-protocol bound in BYTES the attacker must send, and say which stage it
  covers; the keepalive covers the conforming peer.
  `../rounds/275-a-deadline-on-saying-nothing.md`.
- **Round 276** — the websocket `_refuse` drained unbounded and `unawaited`: a
  plain POST held 0 of 16 before, 16 of 16 closed after. Attack the exit, not the
  feature (upgrade-shaped requests carry no body); turning the security control
  (`allowedOrigins`/`allowUpgrade`) on is what opened the path.
  `../rounds/276-the-same-defect-in-the-sibling.md`, bench
  `../probes/P-26-refused-upgrade-has-no-deadline.md`.
- **Round 277** — HTTP/2 Rapid Reset (CVE-2023-44487) CLEAN: 0 handlers from 200
  resets vs 4 from 200 calls; the HPACK/churn CPU half is not measured.
  `../checked/C-32-rapid-reset-dispatches-nothing.md`.
- **Round 361** — the client's mirror stage: `connect()` hung 10016 ms (the
  probe's bound) vs 806 ms with `connectTimeout: 800ms`. The pre-protocol stage is
  where a client AUTHENTICATES (`openWebSocket` forwarded no headers); a new
  parameter must reach the RECONNECT factory too (U-10).
  `../probes/P-52-connect-headers-and-timeout.md`,
  `../rounds/361-the-only-place-to-authenticate.md`.
- **Round 397** — after round 395 drove one http2 exit, `_answerFramingViolation`
  did not `releaseStreamId`: 200 streams kept with the peer still open vs 0
  half-closed. Two refusal exits in one file are two measurements; arms must be a
  PAIR differing by one bit; a refusal must also END a running call.
  `../rounds/397-the-refusal-that-kept-the-stream.md`, `../probes/P-84-what-a-refused-stream-leaves.md`.
- **Round 399** — framing refusal vs served call, 2000 ops: 548 ms vs 873 ms,
  amplification 1.61x vs 0.78x (the diagnostic message, via
  `maxHeaderValueBytes`). Recorded, not fixed; B-58's backstop is not justified on
  cost. `../probes/P-85-what-a-refusal-grind-costs.md`.
- **Round 400** — 20000 refused streams to a non-reading peer plateau at 394
  (`package:http2` queues the trailers-only HEADERS). Producing "the peer does not
  read" takes a relay with its upstream PAUSED; a peer that never calls `listen`
  applies no pressure. `../probes/P-86-a-peer-that-never-reads.md`.
- **Round 532** — a plain GET to the websocket port gave one error record and
  one `onConnectionError` each (10 of 10 vs 0). A refusal's second output is the
  operator's log; measure the answer alongside the noise; fixing a reporting path
  can move a bound (draining now on every server).
  `../probes/P-165-what-does-a-health-check-cost.md`, B-136.
- **Round 591** — B-207's zlib filter left to a finaliser: +30/+31 MiB control vs
  +6/-53 MiB witness over 20000 attempts. A refusal that must do the expensive
  work to decide cannot be driven cheaply and bounds its own cost; name the arm
  expected to GROW before running. `../probes/P-209-what-a-refused-bomb-leaves-behind.md`,
  `../rounds/591-the-refusal-pays-for-its-own-cleanup.md`, B-207.
