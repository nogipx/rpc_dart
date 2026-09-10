---
refines: —
paths: [packages/core/rpc_dart/lib/src/core/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart_compression/lib/**]
applies: an inbound size limit exists, and something buffers before it is consulted
breaks: DoS.
applied: [236, 279, 280]
status: confirmed (round 280)
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

No catalog shape covers this; a candidate for `catalog/` at the next curate,
by the usual test — it holds in any code that buffers untrusted input.

Imported from private memory in the curate pass after round 234.
