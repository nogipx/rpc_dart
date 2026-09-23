---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: —
reason: cost — split out of B-70 item 26; the reachable input has to be constructed before the severity is known
---

# B-78 — ensureGrpcFrame decides "already framed?" by guessing

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

—
