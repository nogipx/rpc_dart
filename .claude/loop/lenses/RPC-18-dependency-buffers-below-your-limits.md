---
refines: —
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: a dependency parses or reassembles the wire before this code sees a message
breaks: DoS.
applied: [237]
status: confirmed (round 237)
---

# RPC-18 — The dependency buffers below every limit you own

## Shape

Your limits sit at the message layer. The dependency underneath reassembles the
wire *before* anything becomes a message — and it has no bound of its own. Every
ceiling you configured is structurally blind to it: the bytes are not a stream
yet, not metadata yet, not a call yet, so nothing that counts streams, headers or
calls can see them.

This is the sibling of `RPC-17-limit-fires-after-residency.md` and the difference
matters when hunting. There, YOUR limit exists and runs too late. Here there is
no limit to run — the buffering belongs to code you do not own, one layer below
the lowest thing you configure.

## Detector

For each transport dependency, enumerate where it ACCUMULATES across wire units
before handing anything up, and for each ask which rpc_dart limit could possibly
see it. In `package:http2` (2.3.1) that is `FrameDefragmenter`, which carries the
standing TODO *"emit an error if too many continuation frames have been sent
(since we're buffering all of them)"*. In `dart:io`'s WebSocket it is
`processIncomingMessage`, which inflates and accumulates into a `BytesBuilder`.

Then the lever question, because you cannot patch the dependency: can you get
BETWEEN the socket and it (a guarded byte stream), or is the only control whether
the feature is negotiated at all?

Existing instances, both live in the tree:
`http2_header_block_guard.dart` (`viaSocket` became `viaStreams(guarded, socket)`),
and the `enableCompression: false` defaults in rpc_dart_websocket.

## Ask

Can a peer make the dependency allocate without ever creating a stream, a
message or a header this code can count?

## Evidence

**The HTTP/2 CONTINUATION flood.** `package:http2` concatenates a HEADERS frame
and its CONTINUATION frames into one unbounded buffer, rebuilding it on every
frame (`Uint8List(old+new)` plus two copies), so N frames cost **O(N^2)** memcpy
on the connection read path. A peer that opens a header block and never ends it
never creates a stream — so `maxActiveStreams` and `halfOpenStreamTimeout` never
see it — and produces no decoded metadata, so `validateMetadata` and `maxHeaders`
never run.

    64 MiB in 4096 CONTINUATION frames  -> +53.7 MiB RSS, and an ordinary call
                                           on ANOTHER connection TIMED OUT
    256 MiB in 16384 frames             -> +92.5 MiB, minutes of CPU
    after the guard                     -> +0.2-0.4 MiB, connection reset,
                                           the concurrent call answered

The concurrent-call timeout is the DoS: one unauthenticated socket starves every
client on the server's single event loop.

**The CALLER side measured WORSE than the server** (81b21020): the same 64 MiB
flood cost **+194.3 MiB** client RSS against +53.7 server-side, with the
transport still reporting open; +2.5 MiB after, the hostile server landing 65 of
4096 frames. All five client connection sites are guarded — plaintext `connect`,
`secureConnect`, the public `viaSocket`, and both proxy branches. *"You dialed
the server" is not a defence*: clients get pointed at compromised endpoints, and
a CONNECT tunnel is a machine on the path that is often not the operator's.

> **Two things were load-bearing and neither was obvious.** The 24-byte
> connection preface must be skipped first — parse `PRI * HTTP/2.0\r\n\r\nSM...`
> as a frame header and you get a bogus length of ~5 MiB, so the scanner skips
> every real frame. The first cut shipped exactly that: a guard that was a silent
> no-op, which let the flood through AND passed a naive baseline, because
> legitimate blocks are small and never trip it. Nothing in the suite caught it;
> re-measuring the flood did.
>
> And `skipConnectionPreface` is a **fail-open switch**: the preface travels
> client-to-server only, so a server must skip it and a client must not. Set it
> wrong and nothing fails loudly. Both mistakes were canaried (cap lifted, and
> the flag left at the server's `true`) and in both the client accepted all 4096
> frames **while the "an ordinary call still works" guard kept passing**. That is
> why the witness asserts on frames-the-attacker-landed, not on RSS or on a
> timeout.

**The in-process test is not a starvation witness.** A flood loop with periodic
`await socket.flush()` yields the event loop, so a concurrent call is answered
even with the guard OFF; starvation only reproduces cross-process. The
deterministic in-process witness is CONNECTION RESET — with the guard a client
write eventually throws, with the cap lifted all 4096 frames land buffered and
nothing throws.

**Round 237 applied it and the shape came back INVERTED**, which is worth as
much as the fix. The detector asks where the dependency accumulates; here
package:http2 accumulates nothing, because `HPackDecoder.decode()` returns
thousands of POINTERS to one shared dynamic-table entry — measured
`distinct: 1`, RSS +7 MiB for 60001 headers, against 229.3 MiB of "logical"
size. Dart's reference semantics defuse the classic HPACK bomb.

rpc_dart's own adapter paid it instead. `http2HeadersToRpcMetadata` calls
`String.fromCharCodes` per header, so every shared reference became its own
String, and it ran one line BEFORE `validateMetadata` — the limit that would
refuse the request could only refuse a copy already made:

    63 KiB on the wire, under the guard, one unauthenticated request
      HPACK decode     RSS   +7 MiB    (distinct: 1)
      the conversion   RSS +258 MiB    <- ~4100x
      after                  +0 MiB, refused

> **When a dependency hands you a cheap representation, the cost moves to
> whoever materialises it.** The detector's question — "which of my limits could
> see this?" — has a second half: my limit runs on the CONVERTED form, so the
> conversion is the thing to bound, not the input. Ask where the representation
> changes, and check that the guard is on the expensive side of it.

Bench `../probes/P-16-hpack-reference-flood.md`; round
`../rounds/237-the-dependency-shared-what-we-copied.md`.

Imported from private memory in the curate pass after round 234.
