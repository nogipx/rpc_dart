---
round: 889
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-22
bench: none — the question is a status mapping, not a quantity; the witness is a unit test with a codec that throws the refusal itself
commit: yes
release: none
---

# Round 889 — a colliding-key refusal reaches the peer as RESOURCE_EXHAUSTED

## Target

Two gaps left by round 887. Its record says `_decodePeerMessage` answers
`CborKeyCollisionException` RESOURCE_EXHAUSTED, but its tests call
`CborCodec.decode` directly and never see a status. The I-8 conformance test
(`i8_decode_is_bounded_test.dart`) checks only the item budget, so it was
blind to 887. Before that: C-97, a sweep for a third peer-filled String-keyed
map in core and the transports, found none.

## Hypothesis

A peer message the decoder refuses with `CborKeyCollisionException` reaches
the other side as something other than status 8 (for example INTERNAL, if the
new exception slipped past the catch), or reaches the handler. Fails to hold
if both directions answer 8 and the handler count stays 0.

## Before

`a_colliding_key_refusal_is_resource_exhausted_test.dart`, in-memory pair, a
codec that encodes normally and throws `CborKeyCollisionException(16)` on
every decode:

```
request refused by the server's codec   -> caller sees 8, handler count 0
response refused by the caller's codec  -> caller sees 8
GUARD the same call, decoding codec     -> ok, handler count 1
```

## Mechanism

n/a (CLEAN). `_decodePeerMessage` catches the exception next to
`CborItemLimitException` and throws `RpcPeerFaultException(resourceExhausted)`
on both the responder and the caller path.

## After

No change to `lib/`. The test stays as the witness of the mapping.

## Canary

The `on CborKeyCollisionException` branch switched in place to `rethrow`: both
witnesses go red, "Expected: ... `statusCode`: <8> Actual:
RpcStatusException(13): Request payload could not be decoded" and the same
with "Response could not be decoded". Restored: `+3`, and `lib/` diff empty.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`: green. The new file on dart2js (`-p node`): `+3`.

## Siblings

Not per transport: the mapping is the one shared decode path. That status 8
from this path travels on every transport is already covered by I-8's rows for
`CborItemLimitException` (channel, http, http2, websocket, isolate, wasm). A
matrix row for the new exception was not added: the matrix's contract has no
hook for a refusing codec, and the only way to make the real decoder refuse is
a crafted key set, which the owner asked not to use here.

## Not fixed

—

## Links

Round 887, C-97, I-8, RPC-22.
