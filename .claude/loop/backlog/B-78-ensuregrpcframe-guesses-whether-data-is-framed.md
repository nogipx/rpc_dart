---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: —
reason: cost — split out of B-70 item 26; the reachable input has to be constructed before the severity is known
---

# B-78 — ensureGrpcFrame decides "already framed?" by guessing

## RE-OPENED (round 457). Round 455's fix was WRONG and is reverted.

The defect below is real and still there. What was wrong is the fix: **the fact is
not a constant.** `parser.dart:212-218` — with NO decompressor, which is exactly
what the http2 transports build, the parser cannot de-frame a COMPRESSED message, so
it re-frames the compressed payload itself and emits a complete frame on purpose.
So the parser's output is a frame for a compressed message and a bare body for an
uncompressed one, and the function genuinely has to tell them apart.

Framing unconditionally therefore double-wrapped every compressed message and lost
the compressed bit: `grpc-encoding: gzip -> status=13 INTERNAL`. That was B-91,
which turned out to be this round's own regression.

**The right fix, still to do**: the parser KNOWS which branch it took and nothing
asks it. Have it say so — a flag beside the payload, or two output shapes — and the
guess disappears without losing the bit. That is a core API change, which is why
round 457 restored the guess rather than improvising one under time pressure.

The hole is characterised by a test, so the day this is fixed properly that test
fails and points here: `a_self_framing_body_is_still_framed_test.dart`, whose name
is now wrong (`mv` is outside the allowlist).

## Round 455's measurement, which still stands

The lead's question answered by reading: `ensureGrpcFrame` is called on the OUTPUT
of `RpcMessageParser` at both call sites, and the parser emits de-framed BODIES
(`result.add(payload)`, `parser.dart:269`). So its input is an application message
body, chosen by the peer.

Measured end to end over a real socket, same body length, one byte different:

```
body 13B, first byte 0x00 (valid flag)  -> payload 13B  UNCHANGED
body 13B, first byte 0x99 (not a flag)  -> payload 18B  RE-FRAMED
```

In the first row the layer above read those five bytes as a header and got an
8-byte message instead of the 13 the peer sent, silently.

**The fix is smaller than B-62's shape**, which the decision named: there was no
fact to carry, because it is a CONSTANT. Both call sites pass parser output, so
the input is always de-framed — `frameParsedMessage` frames unconditionally. The
rename is deliberate: "ensure" is what invites the check back, and the function is
package-internal so it costs no public surface.

A test named *"ensureGrpcFrame does not double-wrap"* was pinning the defect and is
rewritten to the new contract. Two other tests used the function as a framing
helper and only needed the new name.

Left alone: the sibling `isGrpcFrame`, same heuristic as a bool, no callers in
`lib/` — it would let the guess back in without touching this function.

`ensureGrpcFrame` (`rpc_http2_common.dart:517`) decides whether a payload is
already gRPC-framed by PARSING its first five bytes and checking that the
declared length matches the rest. A payload that happens to satisfy that test is
returned unchanged — and its first five bytes are then read as a header.

So the check is a heuristic over attacker- or application-controlled bytes, and
the failure is silent: the message is not rejected, it is re-interpreted.

http2 only; no sibling transport does this.

**What is NOT known**: whether a payload reaching this function can be chosen
freely. If every caller into it has already framed or definitely not framed its
data, the ambiguity is unreachable and this closes as a negative. That question
is the round, and it is cheaper than the fix.

If it IS reachable, the fix is not a better heuristic — it is carrying the
already-framed fact rather than re-deriving it, which is the shape B-62 used for
the envelope.

Bench: construct a payload whose first five bytes are a valid gRPC header for
its own remaining length, send it through each entry point, and see which ones
let it through unchanged.

## Owner decision

**Take it. Establish reachability first; if reachable, carry the fact, do not
sharpen the guess.**

The round is the lead's own question: can a payload reaching `ensureGrpcFrame`
be chosen freely? If every entry point has already framed or definitely not
framed its data, this closes as a negative in `checked/` and costs one round.

If it IS reachable, the fix is B-62's shape — carry the already-framed fact
through the call path instead of re-deriving it from the bytes. A tighter
heuristic (checking the compression flag byte, an exact length match) is
explicitly DECLINED: a better guess over application-controlled bytes is still a
guess, and the failure stays silent, which is the part that matters.
