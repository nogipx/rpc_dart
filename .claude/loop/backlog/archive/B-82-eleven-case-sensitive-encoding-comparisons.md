---
status: closed (round 456)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
probe: —
reason: cost — split out of B-70 item 7; eleven sites, one rule, and the peer that triggers it has to be built by hand
---

# B-82 — eleven sites compare a raw header where the registry normalises

## CLOSED (round 456) — and the reachable path was the OWN caller, not a peer

**This lead had the direction backwards.** It says a hand-built peer is needed
because rpc_dart's own caller always spells it lower-case. The encoding is selected
by a header on the call CONTEXT — `_context?.getHeader(grpcEncoding)` — so a USER
picks the spelling, and the library's own caller reaches it:

```
own caller, grpc-encoding=identity   OK
own caller, grpc-encoding=Identity   status=13 Internal server error
```

From a foreign peer at compression flag 0 the same value is INERT, which is the
opposite of what the lead predicted.

The mechanism, three answers to one question:

```
isSupported('Identity')     true       normalises, nothing refused
'Identity' != 'identity'    true       compression switched ON
compress(enc:'Identity')    unchanged  normalises, no compression happens
```

so the compressed FLAG went out on bytes nothing compressed.

Fixed with one accessor, `RpcGrpcCompression.isIdentity`, at all eleven sites; it
absorbs the `== null` half too. Inbound metadata is not rewritten, as decided.

**A witness over a channel pair would have been worthless** and nearly shipped:
in one process compress and decompress both normalise, so the call round trips on
both sides of the fix. The witness lives in `rpc_dart_http2`.

Beside it, not part of it: `gzip` fails the same way in BOTH spellings, before and
after. Filed as **B-91**.

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

**Take it. Measure what happens today FIRST, then one shared normalising
accessor.**

The measurement decides the severity and is not skippable: the two plausible
outcomes are UNIMPLEMENTED with a usable `grpc-accept-encoding` (acceptable) and
a decompression attempt against a codec that does not exist (not). Build the
hand-made peer, because rpc_dart's own caller always spells it lower-case —
and follow L-10: the body has to come from the library's own `codec.serialize`
or the failure hides behind a default-deny INTERNAL.

The fix is ONE accessor that all eleven sites call, not eleven `toLowerCase()`
calls — otherwise the twelfth site written next year repeats this.

Do NOT normalise inbound metadata in place as a shortcut. It is cheaper and it
is wrong: application code reading raw headers would silently get something
other than what the peer sent.

Accepting `GZIP` / `Identity` where they are refused today is a loosening, not a
break — patch, with a CHANGELOG line.
