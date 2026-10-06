---
refines: U-18
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/**]
applies: identifiers are issued locally and outlive a reconnect
breaks: data loss on a live call.
applied: [217, 218, 224, 234, 527, 541, 643, 661]
status: confirmed (round 661)
---

# RPC-03 — Stream ids that outlive a reconnect

## Shape

The id manager starts numbering from scratch while operations issued before the
break are still alive.

## Detector

`RpcStreamIdManager`, `resumeAfter`, `lastIssuedId`,
`RpcChannelTransport.resumeStreamIdsAfter`, `lastIssuedStreamId` — and then the
two questions those names do not ask. **At every swap site, can the capability be
ABSENT?** Both hops in `RpcClientConnection` guard with `is` and return silently.
**And at every swap site, is the watermark still READABLE when it is read?**
Follow who closes what first, on the path where the PEER starts the drop.

## Ask

Can tearing down a dead operation close a live one that holds the same id?

## Evidence

A dead call's teardown half-closed a LIVE one; both obvious fixes failed.

Round 217 swept the swap sites. Core's `RpcClientConnection`, the websocket
caller's own `reconnect()`, and the http2 and http callers all carry the
watermark; isolate and wasm have no in-place reconnect at all, so the shape
cannot arise there. What is NOT covered is the capability going missing:

    factory returns          id before   id after   handlers ended
    the transport itself         1           3          0 -> 0
    a plain decorator            1           1          0 -> 1

The last column is a live bidi call half-closed by a dead call's teardown.
Bench `../probes/P-09-watermark-survives-a-decorator.md`.

**Round 224 closed that door**, by the only route the two failed attempts left:
stop the collision rather than detect it. A transport that does not implement
the capability is refused at attach, so the watermark is never silently absent.
The decorated arm went `handlers ended 1 -> 0`, the control unchanged.

> **A capability-guarded fix is only as good as what happens when the answer is
> no**, and "return quietly" is the wrong answer when the capability is
> load-bearing. Three outcomes are available — preserve it (round 209's
> `_preserveCapabilities`), work without it (round 218, measured impossible
> here), or refuse (round 224). Silence is not one of them.

> **A capability-guarded fix has the capability's failure modes.** Round 209
> found this for `IRpcFlowControlled` and round 217 for `IRpcStreamIdSequence`:
> whenever a fix reads `is ISomething`, ask what happens to the fix when the
> answer is no, and whether anything says so out loud.

Round 218 tried to replace the capability with a generation ledger inside the
proxy and measured that it CANNOT work: once the ids collide, the new call is
issued the same integer, so tagging by id cannot tell the dead caller's
`finishSending(1)` from the live one's, and refusing to overwrite the tag drops
the live call's own half-close instead.

> **Prevention and detection are not interchangeable here.** The watermark works
> by stopping the collision; nothing that runs AFTER the collision can undo it,
> because the id is the only thing the caller passes. The only capability-free
> alternative is to stop handing the caller the transport's id at all — a
> translation layer with its own id space, inbound direction included.

**Round 234, the third instance, and the first one where the watermark was
present and simply UNREADABLE.** 217 and 224 swept who carries it; nobody asked
whether it still exists at the moment it is read. `RpcChannelTransport.close()`
called `_idManager.reset()`, and on a drop the peer starts, that close is what
TELLS the layer above — so the cursor was rewound before anything could look:

    reconnect on a LIVE socket      idA=1 idB=3 disjoint   <- what every test drove
    reconnect after the peer died   idA=1 idB=1 COLLIDE
    A's late finishSending(idA)     handlers ended 1 -> 2  <- B ended

Fixed at the reset: `releaseAll()` frees the ids and keeps the cursor. Both
reconnect paths were broken by it and both are fixed by it — the websocket
wrapper and `RpcClientConnection`, whose `_retire()` reads the watermark off a
transport that has already closed itself. Bench
`../probes/P-13-ids-after-a-peer-started-reconnect.md`; lesson
`../lessons/L-06-the-path-the-owner-drives.md`.

> **A value kept to survive an event must not be destroyed by that event.**
> `lastIssuedStreamId` is documented "Exists for RECONNECT", and close — the one
> event that starts a reconnect — deleted it. The doc that said "read it BEFORE
> closing" made this look handled; it is advice the layer above cannot follow
> when the close is not its own.

**Round 527 — the INBOUND direction, which the note above named and nobody had
swept.** 217, 224 and 234 all asked about ids THIS side issues, where the
watermark exists. The peer's ids have no watermark available at all: the peer
chooses them and restarts at the bottom on every socket.

The websocket caller's guard is membership in two sets, cleared on reconnect. The
same stale operation, the same id, differing only in whether the peer reopened the
number:

    peer id, peer REUSES it        stale teardown DELIVERED
    peer id, not reused            dropped
    own id (space resumed)         dropped
    CONTROL no reconnect           DELIVERED

Bench `../probes/P-161-does-a-stale-id-reach-the-new-socket.md`. Round 527 fixed
what membership CAN cover — two flow-credit forwards that had no guard at all —
and filed the rest as B-199, because prevention is again the only route and both
remaining forms of it are design changes.

> **Ask the detector's question in both directions.** The three sweeps read as
> exhaustive because they covered every swap SITE; they covered one id SPACE. A
> lens whose fix is "carry the watermark" is silent wherever there is no watermark
> to carry, and that silence looks like coverage.

> **Membership cannot substitute for disjointness.** A set of live ids answers
> "was this ever mine" and the question is "is this the same call" — identical
> until the numbers repeat, which is exactly the case the guard exists for. 218
> measured this for a ledger; 527 measured it for the set.

Round 541 carried the owner's decision out and found the lens's shape **three layers
deep**, not one. A caller on the reused number was handed another call's ANSWER, and its
own request was never dispatched, because the transport's stable stream hides the drop
from the responder pipeline. Bench
`../probes/P-174-what-a-reused-peer-id-answers.md`.

> **A bare `int` in an interface is a teardown's only argument, and it stops
> identifying a call at the connection boundary.** Every layer that resolves one
> LATE is a site: the transport's send guard, a closed responder still writing, and
> the pipeline's own `_cleanupStream` — which took the state it was issued for
> rather than looking the id up again. Where the state object exists, identity is
> the answer and costs one `identical`; where only the int exists, the answer is to
> make the old state unreachable first.
