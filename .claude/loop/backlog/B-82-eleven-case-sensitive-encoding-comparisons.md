---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
probe: —
reason: cost — split out of B-70 item 7; eleven sites, one rule, and the peer that triggers it has to be built by hand
---

# B-82 — eleven sites compare a raw header where the registry normalises

`RpcGrpcCompression` normalises before comparing — `trim().toLowerCase()`
(`compression.dart:118`) — and uses the NORMALISED value at `:124`, `:131` and
`:150`.

**Eleven sites outside the registry compare a raw header value against the
lower-case constant**, so `Identity`, `GZIP` or `gzip ` is a different codec to
each of them:

```
  metadata.dart:98
  unary/caller.dart:114, :499, :513
  base_processor.dart:37, :269, :564, :972, :1135
  unary/responder.dart:87, :287
```

Plus `compression.dart:166` itself, on a token out of `grpc-accept-encoding`.

The count is **11, not the ~12 the original sweep claimed** — corrected on the
re-read, recorded here so nobody re-derives the wrong number.

`identity` is the case that matters: it is the "no compression" sentinel, so a
peer spelling it with any capital produces a value that is neither recognised as
identity nor registered as a codec. What happens then is the measurement — the
plausible outcomes are UNIMPLEMENTED (fine, if the peer is told what would work)
and a decompression attempt against a codec that does not exist (not fine).

Bench: a hand-built peer, because rpc_dart's own caller always spells it
lower-case, so nothing in the ordinary suite can reach this. L-10 applies — the
body has to be built with the library's own `codec.serialize`, or the failure is
invisible behind a default-deny INTERNAL.

The fix, if the measurement justifies it, is one shared normalising accessor,
not eleven `toLowerCase()` calls.

## Owner decision

—
