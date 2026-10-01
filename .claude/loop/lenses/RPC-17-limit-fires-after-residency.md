---
refines: —
paths: [packages/core/rpc_dart/lib/src/core/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart_compression/lib/**]
applies: a size limit exists on one direction, and something buffers in the other before any limit is consulted
breaks: DoS.
applied: [236, 279, 280, 350, 489, 506, 507, 509, 511, 512, 513, 519, 534, 549, 550, 564]
status: confirmed (round 489)
---

# RPC-17 — A limit that fires after the bytes are resident

## Shape

Distinct from "no limit at all", and it reads as safe in review: the limit
**exists**, and it sits one layer too late, so the allocation it was meant to
prevent has already happened when it fires. The reviewer's question "is there a
length check?" is the wrong question. **The question is what runs BEFORE it.**

## Detector

Every inbound buffering site, read as an ORDER OF STATEMENTS rather than for the
presence of a guard: `RpcFrameMultiplexedChannel._onData`, the caller and
responder body readers in rpc_dart_http, every decompressor
(`RpcGrpcCompression.decompress`, `compression_gzip_io.dart`, the
`RpcGzipCodec` in rpc_dart_compression), and `bufferPreMethod` in core.
For each: is the chunk appended to a buffer before the cap is consulted?

Then the second, harder half — **which DIMENSION does each nearby limit
measure?** `maxActiveStreams` counts streams (one is enough),
`maxMessageLengthBytes` bounds ONE frame (each can be legal),
`halfOpenStreamTimeout` bounds time, not volume. The class lives in the gap
between the dimensions, where nothing measures TOTAL BYTES.

Third: a peer-controlled amplification factor. Where the buffer is inside a
dependency that cannot be patched, the only lever is whether to negotiate the
FEATURE at all, and an untrusted-facing default must fail closed.

## Ask

Between the byte arriving and the limit firing, how much is resident? Measure
`ProcessInfo.currentRss`/`maxRss` around one call — the differences here are
40x, so no statistics are needed.

## Evidence

Confirmed repeatedly before the journal existed; every instance below is a real
fix with a sha, and the numbers are why the shape ranks as DoS rather than
untidiness.

    RpcHttpCallerTransport          192 MiB body -> RSS +756 MiB, then the
    (e8c5bc9f)                      parser's own error; +19 MiB after. Resident
                                    three times over: the streamed copy, the
                                    concatenated body, the parser's buffer
    RpcFrameMultiplexedChannel      16 MiB limit, one 256 MiB chunk ->
    (8a1282f0)                      256.2 MiB allocated, 0.1 MiB after. The cap
                                    bounded what was RETAINED, not ALLOCATED
    bufferPreMethod, core           250.7 MiB pushed -> RSS +495.2 MiB; +30.3 MiB
    (a6440b9d, round 90)            after. Three hand-built frames on a plain
                                    WebSocket reach it -- unauthenticated remote
                                    memory exhaustion on every channel transport
    permessage-deflate              ON: 0.25 MiB uploaded -> 516 MiB RSS (2071x);
    (0af1eb44 / 948bd6da,           OFF: 256 MiB uploaded -> 682 MiB (2.7x).
     rounds 74-75)                  Inside dart:io, which has no output bound --
                                    so the fix is to stop OFFERING the extension
    RpcGzipCodec on the VM          4.0 MiB of compressed zeros against a 16 MiB
    (round 107)                     limit -> RSS +1873 MiB over 17.5 s, ~470x.
                                    ISIZE is size MOD 2^32, so the pre-check
                                    clears. +23.9 MiB / 8 ms after

**The asymmetry to look for:** a server bounds what CLIENTS send it and forgets
that it is also a client of its peers. `RpcHttpResponderTransport.readBody`
bounded the request body correctly all along; the caller had no bound in the
other direction and took no policy at all.

**Measured CLEAN — do not re-hunt:** the http2 caller (round 52: same 192 MiB
experiment, RpcException from the 5-byte header, RSS +0 MiB, structurally
immune because each DATA frame goes straight to the parser); message-level gRPC
gzip through core's dart:io codec (rounds 76 and 108: 0.5 MiB expanding to
512 MiB against a 4 MiB cap -> status 13 in 48 ms, RSS +17.9 MiB, handler never
ran); the compressed-flag variants (all three fail cleanly, connection intact).
`../checked/C-16-http2-caller-inbound-buffers.md` and
`../checked/C-17-message-level-gzip.md` hold the first two.

**Known live residual, deliberate:** a large UNCOMPRESSED WebSocket message is
buffered whole by dart:io before delivery, and dart:io exposes no
`maxMessageSize` (searched `_http/websocket.dart` and `websocket_impl.dart`).
Amplification is 1:1 — the attacker must actually send the bytes — which is what
keeps it below the bar rather than merely hard.

> **Two rules this class paid for.** In a regression test assert the error
> MESSAGE where the two layers produce different ones (RSS in a shared runner is
> noisy); where the message is identical by design, RSS is the only witness, so
> give it a 4x margin and **page the source buffer in first** or the growth is
> credited to the test's own allocation. And a bomb is defined by AMPLIFICATION
> (RSS per wire byte), not absolute RSS: disabling compression made the client
> send 256 MiB uncompressed, so a naive RSS probe read the fix as "no change".

**Round 236 applied it for the first time in the journal and found a sixth
instance, through the DIMENSION clause rather than the ordering one.**
`BufferedBroadcastController` — on the inbound path of every transport, six
construction sites — bounded its unlistened queue by EVENT COUNT
(`maxPendingEvents`, 4096) and by nothing else, while its doc claimed memory
stayed bounded. The neighbour bounds one message at 16 MiB, so 4096 x 16 MiB =
64 GiB was admitted:

       16 KiB each   pending=4096   retained   64 MiB
       64 KiB each   pending=4096   retained  256 MiB
      256 KiB each   pending=4096   retained 1024 MiB

The count never moves; the bytes scale linearly. Through a real transport,
+549 MiB with nothing subscribed against +2 MiB with a listener; +58 MiB after.
Bench `../probes/P-15-pending-queue-dimension.md`.

> **A bound whose units are not the units of the damage is not a bound.** Both
> halves of this lens are really the same question asked twice — the ordering
> half asks WHEN the limit runs, the dimension half asks WHAT it counts, and a
> limit can pass one and fail the other. This one ran at exactly the right
> moment and measured the wrong quantity.

**Round 279 found the SAME bound wrong a third time, in the same file.** The
sequence is the point: 236 found it counting EVENTS while the damage was bytes;
245 found metadata weighing ZERO; 279 found metadata weighing its CHARACTERS,
which is the one thing about a header that is not its cost. `["h1","v1"]` weighs
4 and retains an `RpcHeader` plus two Strings — measured at 97, 103 and 111
bytes per header across three scales.

    arm      headers  admitted   wire  weighed     RSS  stopped by
    payload        -       256   16.0     16.0    37.3  the byte bound
    thin         500      4096   30.4     14.8   190.8  the EVENT count  <- before
    thin        2000       943   30.4     16.0   186.4  the byte bound
    thin        5000       351   29.4     16.0   186.3  the byte bound
    thin         500       468    3.5     16.0    20.8  the byte bound   <- after

> **A dimension fixed is not a dimension closed.** Each of the three fixes was
> correct and each left the next one open, because "what does this bound COUNT"
> has as many wrong answers as the value has representations: how many, how many
> characters, how many bytes on the wire, how much is retained. Only the last is
> the damage. When you correct a bound's units, ask whether the new units are
> the damage's units or merely closer to them.

And note where the attacker's optimum sits: 500 headers per frame is exactly the
point where the weighed total stays under the bound right up to the 4096-event
ceiling. A shape that maximises damage per weighed byte is what to construct,
not a shape that looks extreme. Bench
`../probes/P-29-metadata-weighs-characters.md`.

**Round 280 asked the generalisation rather than waiting for a sweep**, and a
grep for every weighing site split them in two. Nine `sizeOf:` sites all route
through `bufferedBytes`, so 279 fixed every queue at once; a SECOND family
charges `payload?.length ?? 0` directly. The pre-method budget was one of them:

    arm       charge  parked  refused   charged      RSS   ceiling
    metadata  old       4000        0  0.00 MiB   789.2 MiB   16.0
    metadata  fixed      106     3894  15.93 MiB   27.6 MiB   16.0
    payload   fixed     4000        0  15.63 MiB   11.7 MiB   16.0

> **Two accountings of the same object drift apart the moment one is fixed.**
> `bufferedBytes` and the pre-method charge weighed the same message
> differently, and only one of them was ever corrected. After fixing a weigher,
> grep for every OTHER expression that measures the same thing — here
> `payload?.length ?? 0` — and check each against the damage rather than against
> the weigher you just fixed.

Still outstanding from that grep, named with line numbers in round 280:
`_fcOweConnection`, `_fcDischarge` and `_fcOnDelivered` charge flow-control
credit by payload length at six sites. That is a backpressure question rather
than a memory bound, so it needs a different observable.
Bench `../probes/P-30-pre-method-budget-weighs-payload-only.md`.

**Round 350 closed that thread, and the answer was that the six sites are
right.** They were suspected of an asymmetry (281 refuted it: nothing charged,
nothing credited) and then of needing to charge metadata after all — and that is
the wrong tool, because HTTP/2 applies flow control to DATA only and exempts
HEADERS by design: a control frame that cannot be sent deadlocks the stream it
is trying to end. The defect was the purest instance this lens has: **the limit
did not fire at all, and the residency was unbounded.** The per-stream view from
`getMessagesForStream` is a plain `StreamController`, and flow control was the
only thing in front of it. Bounded now by the round-279 weigher, the one buffer
that had never asked it.

> **Both halves of the lens can pass while the buffer has no limit at all.**
> WHEN does the limit run and WHAT does it count are questions about a limit that
> exists. The detector list above enumerates buffering SITES for that reason —
> and this site was not on it, because it is not on the inbound parse path; it is
> the per-stream fan-out the parse path feeds. After fixing a weigher, also ask
> which queues the weigher is not applied to.

## Round 489 — the OTHER direction, where there was no limit to be late

Every application above is on inbound data. Round 489 is the same file's
outbound side: `RpcHttpResponderTransport` bounds the request body carefully,
with a comment explaining exactly which number to use and why — and buffers the
whole RESPONSE with no ceiling at all, because HTTP/1.1 cannot flush before the
end.

    produced   peak RSS      caller received
     512 KiB    +8720 KiB    0    (status 8)
    2048 KiB   +12608 KiB    0    (status 8)
    8192 KiB   +40208 KiB    0    (status 8)
      32 KiB       +0 KiB    4    ok

> **Read the direction the lens does NOT name.** "An inbound size limit exists"
> was the `applies:` for four rounds, and it made the outbound buffer in the
> same class invisible. A transport has two sides and a peer can usually make
> either one grow; the one with a careful limit tells you the author thought
> about the threat, not that they covered it.

> **The second column is what turns a cost into a defect.** `received 0` says
> the caller refuses any body over the same ceiling, so every byte past it was
> retained in order to be thrown away. A bound that can only discard what could
> never be delivered has no trade to weigh.

**Measuring RSS needs the largest arm FIRST.** RSS does not return, so in
ascending order every arm after the first reads `+0` whatever happens, and the
first arm mixes warm-up with retention. Largest-first puts the whole measurement
where the warm-up is paid, and the ablation becomes a like-for-like comparison
of that one number: `+57664 KiB` against `+11456 KiB`.

`../probes/P-128-what-an-http1-server-stream-retains.md`,
`../rounds/489-buffering-bytes-the-caller-will-refuse.md`, B-98.

No catalog shape covers this; a candidate for `catalog/` at the next curate,
by the usual test — it holds in any code that buffers untrusted input.

Imported from private memory in the curate pass after round 234.

## The purest form: the check is present and one line too late (round 506)

`_decodeAt` refused an oversized metadata frame with the right limit and the right
message — below `if (data.length < payloadStart + payloadLen) return null;`. That
early return is the "keep buffering" path, so a check underneath it is only reachable
once the payload is entirely resident. A peer dribbling toward a declared 10 MiB
metadata frame got all of it held against a 64 KiB ceiling: `10485769` bytes, 160x.

**So the detector gains a cheap, purely syntactic query: for every limit check, what
is the nearest `return null` / `continue` / `await` ABOVE it, and can untrusted input
reach that first?** Then ask what the check actually reads. Here both inputs were
9-byte header fields, so there was nothing to wait for and the fix was moving three
lines.

> **A test asking "is it refused" passes against this defect.** The limit fires in
> both worlds; only the peak differs. Measure bytes accepted before the error, not
> whether the error arrives — and yield a turn between chunks, or the figure measures
> how fast the probe can write rather than what the buffer held.

And the control must be the SAME size with the limit not applying — here the same
10 MiB without the metadata flag, legal and accepted in full. That pins the cause to
the classification rather than the size, and stops a small after-figure from reading
as a rig that cannot feed the data at all.

> **Check the sibling before designing the fix.** The client path already refused
> this from the header (`frame_multiplexed_channel.dart`, `_refusedFrameHeader`), and
> returns null outright when `closeOnOversizedFrame` is true — the server's default.
> Half the codebase had it right, which both confirms the intended behaviour and says
> where to look.

`../probes/P-144-how-much-is-held-before-the-refusal.md`,
`../rounds/506-the-limit-that-waited-for-the-payload.md`, B-115.

## Ask what the buffer is FOR, not only what bounds it (round 507)

The same reassembly buffer, one round later, with no limit involved at all. Every
inbound chunk was copied into it — including when it was EMPTY and the chunk already
held whole frames, which is the ordinary case on a message-aligned transport. The
buffer exists for frames split across chunks; where that does not happen the copy went
in and straight back out as views. `389.76 -> 191.45 us` per 1 MiB frame end-to-end.

So beside "is the limit consulted before the bytes land", ask **"is the buffering
needed on this path at all"**. A buffer written unconditionally is a buffer whose
purpose has not been checked against its callers.

Three things this round paid for, all worth carrying:

> **Measure the layer the lead names.** The first bench echoed through
> `RpcCallerEndpoint`; at 1 MiB the JSON codec dominates everything, so the number
> would have been real and attributed to the wrong code.

> **A cost fix has no witness, only guards.** Nine framing tests, all of which pass
> with the fix ablated — as they must, since the old path was also correct. They were
> labelled WITNESS in the first draft and the ablation corrected it. The witness is
> the bench; the guards exist so the speed-up cannot be bought with a framing bug.

> **Report the honest row.** Removing a copy made the "nobody reads the payload" arm
> 725x faster, which is the absence of work rather than throughput. The row that
> describes a real receiver — one that RETAINS the message and must copy it out —
> improves 2x, and that is the number the record leads with. Keep a size where the
> fix must change NOTHING (64 B here) as the control.

And state the reach: the old path sustained 2566 MiB/s where any real link does one to
two orders less. A measured, free improvement that no user can observe is still worth
having and should not be written up as if it were a fix to a hang.

`../probes/P-145-what-the-receive-path-copy-costs.md`,
`../rounds/507-the-copy-that-bought-nothing.md`, B-116.

## A fix that empties a loop rarely removes it (round 509)

Round 505 gave the scalar middleware helpers an `isEmpty` early return. Round 509
found the `async*` STREAM wrappers around them still iterating an empty list once per
message — the work inside the loop was gone, the loop was not. ~1.03 us per message,
19%.

**So after any "skip the work when there is nothing to do" fix, ask what still runs
to discover there is nothing to do.** An early return inside a callback leaves the
per-element machinery — the `async*`, the `await for`, the awaited call — entirely in
place, and that machinery is usually the larger half.

> **Such a fix often moves a decision from per-element to once, and that is a
> contract change.** Bypassing the wrapper means `_middlewares` is read when the
> stream is BUILT rather than per message, so a middleware added mid-stream no longer
> joins the call. Write it as a test with the reasoning, not as a footnote — round
> 505 had recorded the per-message re-read as *preserved, not decided*, which is
> exactly the note that let 509 decide it deliberately.

> **And two run sets are not a measurement.** The first comparison read `4.710`
> against `5.763` medians and looked settled; the next set's median of `5.949` would
> have reversed it. Report run-set MINIMA when noise only ever adds time, and collect
> enough sets that the two never overlap.

`../probes/P-147-what-an-empty-middleware-wrapper-costs.md`,
`../rounds/509-the-wrapper-around-an-empty-list.md`, B-118.

## Ask what the work is FOR — including a guarantee nobody needs (round 511)

The same question applied to a property rather than a buffer. `_uniqueToken` draws
from the system entropy source. What are the ids for? Correlating log lines — and
`_strongRng`'s own doc says exactly that: *"correlation in logs and on the wire, never
secrets or capability tokens"*. A guarantee the code documents as unnecessary cost
~40 us of every ~97 us unary call, twice per call.

**So the detector extends past buffers and limits to GUARANTEES: cryptographic
randomness, ordering, durability, uniqueness. For each, find where the code says what
it is for, and check whether the guarantee exceeds it.** The justification for
weakening it is often already written down, because whoever chose it wrote down why
it did not matter.

> **Ablate the thing itself and re-time the real path.** A microbench of
> `Random.secure()` is open to the objection that it does not measure what a call
> pays. Forcing `_strongRng` to null — a path the library already takes on node —
> and re-timing the whole call is what turns 196x-in-isolation into 40 us-per-call.
> The microbench then serves as a check: it predicted ~62 us against ~40 us measured,
> close enough to confirm the mechanism, far enough to show why the end-to-end arm
> was needed.

> **And a cost measured OUTSIDE the path is not a share of it.** The same probe timed
> a 6-link context chain and an earlier draft reported it as "37.8% of a call" — a
> synthetic construction quoted as a fraction of a figure it was never measured
> inside. Either measure it within the call or say plainly that it is not a share.

Where this ends is often a DEFERRAL rather than a fix: the change was one line, and it
still belonged to the owner because it alters a documented security posture. Measure
it anyway — the number is what makes the decision possible.

`../probes/P-149-what-the-id-draws-cost-a-call.md`,
`../rounds/511-forty-per-cent-of-a-call-is-entropy.md`, B-120.

## The work that exists to AVOID work (round 512)

The sharpest version of this lens's question. `if (_log.isInternal)` is prescribed
around every interpolating log call, and `CLAUDE.md` calls it "a bool read". It walked
every configured scope override with a `startsWith`: `235.5 ns` at twenty overrides
against a real bool read's `1.8 ns`.

**So when a guard exists to be cheaper than what it guards, measure it against what it
is CLAIMED to be, not against what it guards.** It will always beat the thing it
avoids; that is not the question. The question is whether it is what the surrounding
convention promises, because that promise is why it was put at hundreds of sites.

> **The control has to be the claimed thing, literally.** `LogScope.noop`'s
> `isInternal` is a literal `false`, so it measures the bool read the doc describes.
> It gave the 235 a scale AND kept the round honest afterwards: the fix reaches
> 12.6 ns, which is 7x a bool read, not 1x, so the convention's wording is still not
> true and the record says so.

> **The same control says who was paying.** The library's idiom is
> `_log = logger ?? LogScope.noop`, so an application configuring no logger got the
> 1.8 ns path everywhere. A round that reported "235 ns per guard, hundreds of sites"
> without that would be describing a cost almost nobody paid.

**A cache is a fix that adds a risk the defect did not have, so it needs TWO
ablations.** Bypass the cache: the bench returns and — the useful part — every test
still passes, because the slow version was correct, which is what proves they are all
guards. Then remove the invalidation: the staleness tests fail, which is what proves
they guard the new risk. A round doing only the first would ship a cache with
untested invalidation.

And look for the configuration field with no setter to hook. `minLevel` here is a
public mutable field; the cache remembers which value it was built under rather than
requiring an API change.

`../probes/P-150-what-the-log-guard-costs.md`,
`../rounds/512-the-guard-that-was-not-a-bool-read.md`, B-121.

## The work that does the OPPOSITE of what it is for (round 513)

Compression exists to make messages smaller. Applied to every message it made small
ones bigger: an incompressible 32 B payload went `42 -> 62` bytes, gzip's fixed
overhead being about twenty. So the lens's question has a third answer beyond "is
this work needed" and "is it needed HERE" — **does it achieve its own purpose on
this input?**

**Where an operation can fail its own purpose, the cheapest fix is to check the
result rather than to guess in advance.** The lead asked for a size threshold; comparing
the compressed length against the original is strictly better, needs no number to
tune, and keeps savings a threshold would discard. It is available here only because
the format carries a per-MESSAGE flag — look for that before designing a cutoff,
because a format that already lets each message say what it is turns a policy
question into an `if`.

> **Choose the probe's input from the claim's DIRECTION.** The first version used
> `'a' * n` — maximally compressible — while testing whether compression makes
> messages BIGGER. That is the input least likely to grow, and it duly reported a
> saving at 32 B, which would have refuted a true claim. Ask which input makes the
> claimed failure most likely, use that, and keep the opposite as the control.

> **That control then earns its keep twice.** The repeated-character rows proved the
> rig reports savings when they exist, AND supplied the argument against the
> threshold: gzip beats plain even at 32 B when the bytes repeat.

And a lead filed at `medium` confidence deserves its claims separated before either
is acted on. Two were bundled here; one was confirmed and one refuted, and a round
that took them together would have had to call the whole lead one thing or the other.

`../probes/P-151-does-compression-make-a-message-bigger.md`,
`../rounds/513-the-compression-that-grew-the-message.md`, B-122.

## Count it where ALL of it is visible (round 519)

One deadline is one fact about a call, and the machinery for it is per-OWNER. Three
layers each arm their own timer, and no one of them can report the total — so a Zone,
which sees every `Timer` whoever creates it, is the instrument. Counting by reading
would mean trusting the reading found them all, which is the thing this lens is
usually about in the other direction.

> **Put the whole system inside the instrument.** A subscription creates its timers in
> the zone it was registered in, so building the endpoints outside the counted zone
> left every RESPONDER timer uncounted — the half the lead was about. The rig reported
> `1.0 timers/call` with the deadline apparently free. **A measurement that makes a
> claim VANISH deserves the same suspicion as one that confirms it too easily**, and
> the tell was the same: two arms reading identically.

> **The control is what makes a count attributable.** The lead asks what a DEADLINE
> costs, so the no-deadline arm is the measurement; an absolute `4.0` leaves open how
> much of it the deadline caused. Here the control also produced the larger finding —
> nine timers on a server stream before any deadline exists, bigger than the subject
> and outside it.

**And a count is not a design.** Knowing a deadline costs 2 or 5 timers does not say
which of three arming sites is redundant; that needs each creation attributed to its
stack. Declining the fix on those grounds is the same judgement round 518 made, for
the same reason: a plausible change to one layer of a multi-layer mechanism can be a
regression rather than a partial win.

`../probes/P-156-how-many-timers-does-a-call-arm.md`,
`../rounds/519-nine-timers-before-the-deadline.md`, B-127.

**Round 534 — a paused consumer IS a limit, and it bounded only delivery.**
`RpcWebSocketChannel`'s `_incoming` had no `onPause`/`onResume`, so pausing it stopped
hand-over and nothing else: every chunk was still read off the wire and held in a
controller bounded by nothing.

    consumer PAUSED             5000 pulled    0 delivered
    CONTROL not paused          5000 pulled    5000 delivered
    CONTROL paused then resumed 5000 pulled    5000 delivered

`../probes/P-167-does-pause-reach-the-socket.md`, B-138.

> **When the obvious reading is memory, reframe to DEMAND.** P-128 established RSS
> across arms here is noise. "Did the limit reach the producer" is a count instead: an
> `async*` source increments before each yield and suspends while paused, so the
> counter answers the question with no allocator in the loop.

> **Read both sides of the limit.** `pulled` and `delivered` are the whole finding —
> the defect is precisely that they disagree, and either alone is consistent with a
> channel that works or one that has stopped reading entirely.

> **A contract gap is worth closing and worth GRADING as one.** Nothing in rpc_dart
> pauses a channel, so this changed no behaviour in the library; it closes the
> `IRpcChannel` promise that `incoming` is an ordinary Stream. Say which of the two a
> round did, because "fixed" over an unexercised path reads like a defect repaired.

> **Check the layer below before blaming the layer.** dart:io already wires its own
> controller's pause to the socket subscription; the chain was complete except for one
> link. That is also the argument that forwarding is safe rather than novel.

## Round 564 — the ledger nothing reported, and a zero that guarded nothing

`_halfClosedLocal` was the one per-stream map the http2 caller's `health()` did not report, while every
sibling is reported precisely because growth in one is the symptom of an entry added and never removed —
and it is the map whose add sits after an await.

> **A ledger with no observable cannot be measured, so its defect cannot be closed.** Two rounds
> declined to apply a one-line guard for want of a witness; the thing actually in the way was that
> nothing could count the set. Exposing it is not the fix and is the precondition for one.

> **A zero is not evidence that something is empty — it can mean nothing ever filled it.** Two canaries
> dropped BOTH removal paths for the map and the test still passed, which proves the shapes under test
> never populate it. Asserting `== 0` there would have shipped as coverage for a leak it cannot see, and
> the lead would have read as guarded. Ablate the REMOVALS, not just the adds: if a count stays at zero
> with nothing cleaning up, the arm is not driving the mechanism.

`../rounds/564-the-unreported-map-and-a-vacuous-zero.md`, B-184.
