---
round: 455
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-107 — new
commit: yes
severity: S1
---

# Round 455 — the guess over bytes the peer chose

> **THIS ROUND'S FIX WAS WRONG AND IS REVERTED — see round 457.** Its
> MEASUREMENT stands: the heuristic is reachable and does turn a 13-byte message
> into an 8-byte one. Its PREMISE does not. "Both call sites pass parser output,
> which is de-framed by construction" is false in one branch, and it is the branch
> http2 always takes: with no decompressor the parser cannot de-frame a COMPRESSED
> message, so it re-frames the payload itself (`parser.dart:218`) and emits a
> complete frame on purpose. Framing that again lost the compressed bit and broke
> gzip entirely — filed as B-91, closed in 457 as this round's regression.
>
> The reading error, kept because it is the transferable part: `result.add(payload)`
> was quoted as evidence that the emitted value is de-framed, without reading the
> twenty lines above it that reassign `payload`. **A quote is evidence for what the
> quoted line does, not for what the variable holds.**

## Target

B-78, and its own instruction was the round: establish whether a payload reaching
`ensureGrpcFrame` can be chosen freely, because that is cheaper than the fix and
decides whether there is one.

## Hypothesis

The heuristic reads the first five bytes of its input and returns the input
unchanged when the declared length matches the rest. If the input is an
application message body, a body that happens to look like a frame is handed
upward with five of its own bytes read as a header.

## Before

**Reading settled the shape first**, and it is what made the arm constructible:
`ensureGrpcFrame` is called on the OUTPUT of `RpcMessageParser`, at both call
sites, and the parser emits de-framed BODIES — `result.add(payload)`,
`parser.dart:269`. So the bytes it inspects are an application message body.

```
                              payload the transport handed up
body 13B, first byte 0x00     13B   UNCHANGED (heuristic fired)
body 13B, first byte 0x99     18B   RE-FRAMED (correct)
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/framed_body_survives_unchanged.dart`

Same body LENGTH in both arms, one byte different. In the first row the layer
above then read those five bytes as a header and got an 8-byte message instead of
the 13 the peer sent. Nothing is rejected; the message is re-interpreted.

## Mechanism

The function's NAME is the defect. "Ensure" invites a check, and the check cannot
be made safely: the only evidence available is the bytes themselves, and they are
the peer's. Meanwhile the fact it was guessing at is known statically — both call
sites pass parser output, which is de-framed by construction.

## After

`frameParsedMessage`, which frames unconditionally, and whose name says what its
input is. Both arms read `18B RE-FRAMED`. Renamed rather than just gutted, because
the old name is what would invite the heuristic back; the function is
package-internal (`_index.dart` re-exports only `RpcHttp2StreamError`), so the
rename costs no public surface.

## Canary

The heuristic restored in place:

    Expected: <18>
      Actual: <13>
    the parser emits de-framed bodies, so this one needs a frame like any
    other; guessing from its bytes loses five of them

`+1 -1`, with the control — a body whose first byte cannot be a compression flag —
green on both sides.

## Gate

`melos run analyze` SUCCESS. `test:unit` SUCCESS over 14 packages;
`rpc_dart_http2` 245 passed, up four. `format:check` and `license:check` SUCCESS.

**Four test files referenced the old name and they split two ways**, which is
canary.md item 9 in practice:

- `http2_server_initiated_stream_test.dart` and `metered_on_every_call_test.dart`
  used it as a FRAMING HELPER on raw data. Renamed, no behaviour change.
- `grpc_wire_compliance_test.dart` had a case named *"ensureGrpcFrame does not
  double-wrap"* which **pinned the defect**: it asserted that an already-framed
  input comes back unchanged, which is the branch that fires on a peer's body. It
  stood only on what was removed, so it is rewritten to the new contract — a body
  that LOOKS framed is framed anyway — with the measurement in the comment so the
  reversal is not silent.

## Not fixed

**The sibling `isGrpcFrame` still exists and has no callers in `lib/`.** It is the
same heuristic with the answer returned as a bool rather than acted on, and the
compliance test uses it as an assertion helper. Left alone: it is not reachable
from a wire path, and removing a test helper is not this round's business. Worth
knowing it is there, because it would let the guess back in without touching
`frameParsedMessage`.

## Links

- RPC-25 — the fact was known at both call sites and re-derived at the callee;
  the same shape as round 446's unreachable second home, one level down
- P-107 — does a body that looks like a frame survive unchanged
- B-78 — closed by this round
- B-62 — the shape the decision named: carry the already-framed fact rather than
  re-deriving it. Here the fact turned out to be a constant, so it is carried by
  the function's contract instead of a flag
