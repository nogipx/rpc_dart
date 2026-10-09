---
file: packages/core/rpc_dart/.dart_tool/probe/b209_which_wire.dart
round: 544
commit: d0b960db
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
---

# P-176 — which wire does `maxMetadataBytes` mean?

## Why it exists

B-209's owner decision was "the field names the WIRE, and `validateMetadata` counts the same
quantity". That is one sentence with one wire in it, and the repository has two carrying
metadata plus a third quantity in the policy. Before implementing a decision, price its
premise.

## The harness

Three counts of the SAME `RpcMetadata`, side by side: the text total `validateMetadata`
accumulates, the JSON payload a frame channel encodes, and the `name: value\r\n` block HTTP/1.1
sends.

**The knob is the SHAPE**, not the size: many small headers against few large ones. A
per-header framing overhead is invisible in the second and dominant in the first, so a single
size would have made the three numbers look equivalent.

The JSON figure mirrors `RpcChannelFrame._encodeMetadataPayload`, which is private. That is a
stand-in for the code under test and its risk is real — it is why the round's TEST uses the
public `RpcChannelFrame.encodeMetadata` instead, and why this probe's job ends at sizing the
question.

## The numbers (round 544)

```
  shape                         text      json      http   json/text  http/text
  1 x 8192 B                     8194      8231      8198       1.00       1.00
  8 x 8192 B                    65552     65645     65584       1.00       1.00
  64 x 1024 B                   65718     66259     65974       1.01       1.00
  128 x 64 B                     8594      9647      9106       1.12       1.06
  128 x 8 B                      1426      2479      1938       1.74       1.36

  per-header framing overhead, derived
  8 x 8192 B                  json   11.6 B/header   http   4.0 B/header
  128 x 64 B                  json    8.2 B/header   http   4.0 B/header
  128 x 8 B                   json    8.2 B/header   http   4.0 B/header

  100 quote chars in one value    text 101   json 227   ACCEPTED by the policy
  100 ordinary chars              text 101   json 127
```

## Measures

Bytes, three ways, for one metadata object. Nothing about acceptance except the last line,
which asks the policy directly.

## Control

**The `1 x 8192 B` and `8 x 8192 B` rows**, where all three counts agree to within 1%. Without
them the divergence at `128 x 8 B` could be an artefact of the counting rather than a property
of the shape — they show the three formulas measure the same thing and differ only in framing.

**The two 100-character rows against each other** are the second control and the decisive one:
identical text length, one encoding to 127 bytes and the other to 227. The only variable is the
CONTENT of the value.

## What it establishes, and what it does not

Establishes that "the wire" is not one quantity: JSON costs ~8.2 B/header and HTTP exactly
4.0 B/header, so any per-header surcharge added to the policy is right for at most one
transport. And that the JSON size is a function of the value's CONTENT, not its length — so no
figure derived from lengths can equal it, which is what the decision asked for.

Does NOT measure http2's HPACK block, which is a third framing with its own compression and
would only widen the spread.

Does NOT establish severity. The gap between the policy's count and a wire is bounded by
`maxHeaders` times that wire's per-header overhead — at the defaults, 512 bytes on HTTP against
a 64 KiB field — and this probe does not exercise a peer trying to exploit it.

## Reading

rpc_dart + rpc_dart_http — **prices a decision's PREMISE before it is
implemented.** Three counts of the same metadata side by side: the text
`validateMetadata` totals, the JSON a frame channel encodes, the header lines
HTTP sends. The knob is the SHAPE, not the size — a per-header framing
overhead is invisible at few large headers (all three agree within 1%, which
is the control) and dominant at many small ones. Two refutations: the framing
differs by transport (`8.2` B/header JSON against exactly `4.0` HTTP), and the
JSON size depends on a value's CONTENT rather than its length (`127` bytes
against `227` for the same 100 characters). Its JSON figure copies a private
encoder, which is why the round's TEST uses the public `encodeMetadata`
instead — a bench may stand in for the code under test to size a question, a
regression test may not.
