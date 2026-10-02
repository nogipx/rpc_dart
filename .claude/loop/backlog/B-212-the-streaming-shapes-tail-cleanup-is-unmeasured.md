---
status: open
round: 615
commit: e3c2e4b1
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-174
reason: "round 615 answered the streaming shapes (all served across a reconnect, handler told) and fixed the peer-bidi defect its guard found; what is left is the race against a factory that returns an already-open channel. Previously: the two things round 541 fixed by CONSTRUCTION rather than by measurement: the six streaming `responder.done` cleanups got `only:` by inspection, and whether the reclamation can lose its race against the new socket's first frame is left to the reconnect's own awaits"
---

# B-212 — the streaming shapes and the race round 541 did not price

Split out of round 541, which fixed the unary path with a witness and left two things
argued rather than measured. Bench `../probes/P-174-what-a-reused-peer-id-answers.md`
drives only unary.

## The streaming shapes — ANSWERED in round 615

Server-stream, client-stream and bidi each serve the second caller its own answer
across a reconnect, and each parked handler is told (`P-219`). What follows is the
question as it stood.

Round 541 found that `_ensureUnaryResponder`'s trailing `await _cleanupStream(streamId)`
ran with a stale id after a reconnect and tore down the call that held the number by
then. The four streaming shapes reach the same line through
`responder.done.whenComplete(() => _cleanupStream(streamId, only: state))` — six sites,
all of which got `only:` in that round **by inspection**.

That is the same shape, and `responder.done` can complete arbitrarily late, so the
argument is a good one. It is still an argument. What is not established:

- whether a streaming responder parked across a reconnect keeps its request feed at all
  (`_pipelineFedRequestStream` attaches a sink to the state the reconnect abandons);
- whether the wrapper's cancellation notice reaches a bidirectional handler the same way
  it reaches a unary one — the notice is consumed by `_handleClientCancellation`, which
  closes the responder, and a `ClientStreamResponder` awaiting `requests` unwinds
  differently from a parked `Future`;
- whether `deferFlowCredit`'s claim on the abandoned stream is released.

P-174 extends to these: give the contract a server-stream and a bidi method and park
them the same way.

## The race

The notice is emitted before the reconnect's awaits — `_fwdSub.cancel()`,
`_inner.close()`, then the factory handshake — so the pipeline's reclamation has that
whole window to run in, and in every measured run it did. The rig does not vary the
handshake latency, and an in-process factory would shrink the window to nothing.

**If the new call's opening frame ever won**, the notice would arrive for a state that is
already the new call's, and `_handleClientCancellation` would cancel THAT — the new call
killed instead of a wrong answer. One step milder than the defect, and exactly the failure
direction B-199's owner decision warned about.

Worth knowing whether it is reachable, because the answer decides whether the ordering is
a property of the code or of how long a socket takes to open. The arm is a reconnect
factory that returns an already-open in-memory channel.

## Owner decision

—
