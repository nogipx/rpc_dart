---
status: closed (round 382)
round: (not re-measured)
commit: 34aeff10
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: — (P-65 exists for the other direction and is the shape to point round)
reason: bench — named by 374 and still listed as a gap by 377; it is the one bidi direction three FIXED rounds did not measure, and it is the direction a file upload travels
---

# B-51 — the REQUEST direction of `_pipelineFedRequestStream` is unmeasured

**Filed from the consumer rather than by a round**, after 378 — hence
`round: (not re-measured)`. Rounds 374 and 377 both named this gap in their own
`## Not fixed`; what this record adds is the consumer's numbers for why it is
the expensive direction.

Round 374 fixed the response relay of `_pumpBidirectionalResponses` and said so
plainly in its own "Not fixed":

> The REQUEST direction of the same pump was not measured. This round's class
> was the response relay named by 371; the request side reaches the handler
> through `_pipelineFedRequestStream`, a different mechanism with its own
> deferFlowCredit accounting and its own bench.

Round 377 still lists it as an open gap. So across 370, 371, 374 and 378 the
loop has measured the same missing pause four times — `requestSink`,
`responseSink`, the pump's response relay, and all of it again over a real RTT —
and the one direction left is the one that carries bulk.

## Why the consumer cares, specifically

Filed from rhyolite, at the owner's request, because this is now load-bearing
for us rather than hypothetical.

Our blob upload is a bidirectional contract handler (`async*`) that receives
256 KiB frames and streams each blob into object storage. The bytes of every
upload travel the exact path this lead names: caller → pipeline →
`_pipelineFedRequestStream` → handler. The response direction, which 374 and 378
proved bounded, carries about four acknowledgement messages of ~100 bytes per
call. The ratio is roughly 8 MB in against 400 bytes out — so the direction that
has been measured four times is the cheap one, and the expensive one has not
been measured at all.

If the request relay buffers the way the response relay did (2000 messages /
31.3 MB against a 1 MB window, P-65), a handler that is slow for an ordinary
reason — an object-store write — lets the pipeline pull the client's whole batch
into server memory. On our numbers that is bounded at about 8 MB per in-flight
call by how much a client will ever offer at once, times the calls a server
carries. Not a crash; a memory profile nobody chose.

## What would close it

P-65's rig, pointed the other way: a bidi contract handler that reads one
request and stalls, a small window, and a count of how many requests the
PIPELINE pulled — counted at the caller's producer, so it measures demand the
library created. Control: the client-stream shape on the same rig, whose
`ClientStreamCaller.call` pause is already the value the other three rounds
landed on.

Worth running the ablation through toxiproxy as 378 established, since this is a
flow-control question and P-58 is the standing warning about the in-process
pair.

## What this is NOT

Not a claim that it is broken — nobody has looked. Three sibling mechanisms in
the same file family were all found unbounded, which is a reason to measure and
not a measurement.

## Measured — round 382: bounded, and the path was misattributed

```
arm             pulled of 2000      MB
bidi-stall            66           1.0
bidi-drain          2000          31.3     <- control: the rig CAN pull it dry
client-stall          66           1.0     <- control
```

Bounded at the window. **And the ablation corrected this record's premise**:
removing `deferFlowCredit` from `_pipelineFedRequestStream` moved `client-stall`
to 2000 and left `bidi-stall` at 66. That method is the CLIENT-STREAM path —
`_ensureBidirectionalResponder` binds through `_stateBoundStream`, so a bidi
handler is fed by the transport's own per-stream metering instead.

So there are two request paths, both bounded, by two different mechanisms. The
answer the consumer wanted is unchanged: their upload is a bidirectional
handler, and that path is bounded.

## Owner decision

None needed to MEASURE it, which is what the lead asks for. A decision would
only arise if the measurement comes back unbounded and the fix turns out to
trade something — the three siblings did not, since forwarding a pause changes
when the producer runs and nothing else.
