---
round: 277
status: active
class: fixture
cost: 2 bench rebuilds and 4 probe runs, on a round whose bench budget is 3
commit: dcf9d587
paths: [packages/core/rpc_dart/lib/src/codec/**, packages/core/rpc_dart/lib/src/core/protocol.dart]
---

# L-10 — a hand-built peer must use the library's serializer

A bench that speaks to the server as a raw HTTP/2 client has to produce a
request body. Building it by hand is the obvious move and it cost round 277 two
rebuilds and four probe runs, because **rpc_dart's wire format is CBOR and
nothing in the request shape says so.**

    body                    handler entered   grpc-status
    '"x"'          (JSON)         0               13
    '{"v":"x"}'    (JSON)         0               13
    _codec.serialize('x'.rpc)     1                0

## Why it is worse here than it sounds

The server knows exactly what is wrong and **deliberately will not say.**
`wireStatusFor` in `core/protocol.dart` is DEFAULT DENY: anything that is not an
`RpcStatusException` or one of rpc_dart's own `RpcException`s is replaced with
`kInternalErrorWireMessage`, the literal string "Internal server error". That is
correct — it exists because a `FileSystemException` was handing peers
`path = '/etc/private/key.pem'` — and it means an outside bench gets the same
opaque 13 for a bad codec, a bad path and a handler bug.

So the failure does not look like a fixture problem. It looks like a finding.

## The rule

Build the fixture with the library's own encoder — `codec.serialize(msg)` — and
never with a literal. `methods/tests.md` item 4 already says this for controls;
this is the same rule for anything a raw peer sends.

And when a hand-built request comes back INTERNAL with no detail, suspect the
FIXTURE before the library. The cheap discriminator is a `diagnose` arm that
sends ONE request and prints every response header: grpc-status 0 plus a data
frame means the bench is valid, and anything else means it is not yet.

## What caught it

The control arm. Both arms read `handlers entered: 0`, which is
`methods/measurement.md` item 4 exactly — if the control shows the same symptom
as the case under test, the bench is wrong, not the library. Without a control,
round 277 would have reported "rpc_dart does not dispatch handlers for
rapid-reset streams" on the strength of a probe that could not dispatch a
handler at all.
