---
round: 397
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-84 — reused
commit: yes
---

# Round 397 — the refusal that kept the stream

## Target

The second refusal site in the http2 responder, which C-46 listed as uncovered.
`_answerRejectedStream` handles a request refused in the HEADERS; round 395
measured it and found it releases. `_answerFramingViolation` handles a request
refused in a DATA frame, and nobody had driven it.

RPC-22: every guard on the accepted path has to be asked of the refusal path
separately. Here the guard is `releaseStreamId`, and the two siblings sit 200
lines apart in one file.

## Hypothesis

`_answerRejectedStream` releases the stream in a `finally` after answering.
`_answerFramingViolation` does not — it fires the trailer and returns — so
whether the server reclaims the stream depends on the PEER setting END_STREAM.

## Before

P-84 reused, three arms added: a bad frame WITH a half-close (the ordinary
client shape), the same frame WITHOUT one, and a bad frame arriving mid-upload
into a handler that is already running. The hostile request is five bytes —
valid headers, then a gRPC prefix declaring 32 MiB against the 16 MiB default,
which the parser refuses on the prefix alone.

200 requests on ONE connection, read from the server's own `health()` while it
is still open, plus the endpoint's `activeResponders`:

```
arm                      incoming  subs  parsers  pumps  responders  peer saw
streaming, mid-answer       200      0      0      200      200      (mid-response)
open, never ended           200    200      0        0        0      -
served (grpc-status 0)        0      0      0        0        0      grpc-status 0
half-closed, no body          0      0      0        0        0      grpc-status 3
refused (:method GET)         0      0      0        0        0      grpc-status 3
bad frame, half-closed        0      0      0        0        0      grpc-status 8
bad frame, still open       200    200    200      200        0      grpc-status 8
bad frame mid-upload          1      1      1        1        1      grpc-status 8
```

The server ANSWERED every one of those 200 — `grpc-status 8`, END_STREAM, the
call is over as far as the protocol is concerned — and then held the stream, its
inbound subscription, its parser and its outgoing pump for the life of the
connection.

**`refused (:method GET)` is the arm that shows this is not a peer-behaviour
result.** Both refusals are answered the same way; the one whose site releases
reads 0 and the one whose site does not reads 200.

## Mechanism

`_handleIncomingData` catches the parser's throw and calls
`_answerFramingViolation`, which sends trailers and returns. `_incomingStreams`,
`_outgoingPumps`, `_streamParsers` and `_streamSubscriptions` are pruned in
exactly one place, `releaseStreamId`, and on this path nothing calls it: the
offending frame is dropped, so no payload ever reaches the pipeline and no
responder is dispatched to end the call. The only thing that used to reclaim the
stream was the peer's own END_STREAM, arriving through `onDone`.

Bounded by `maxActiveStreams`, so what it buys an unauthenticated peer is its
own connection wedged for five bytes per slot, not unbounded growth — the state
still dies with the socket. Stated plainly rather than as a leak without a
ceiling.

The mid-upload arm is the same defect one layer up. The parse error reaches a
running handler's request stream, but nothing CLOSES that stream, so a
`Collect`-style handler sits in its `await for` forever — 1 responder still live
600 ms after the refusal.

## After

Both halves, in the `finally` that `_answerRejectedStream` already had:

```
arm                      incoming  subs  parsers  pumps  responders  peer saw
bad frame, still open         0      0      0        0        0      grpc-status 8
bad frame mid-upload          0      0      0        0        0      grpc-status 8
```

The handler still saw its 2 uploaded messages before the refusal, and the peer
is still told `grpc-status 8`. Every other arm is unchanged, including both
retention controls (`streaming, mid-answer` at 200 pumps, `open, never ended` at
200/200).

## Canary

The variation that could break was the one the unary arms never produce: a call
the PIPELINE is running on that id, since a unary responder is not dispatched
until its payload arrives. A client-stream upload — two good messages, then the
bad frame, no half-close — is that case, and it is where the second half came
from.

**Both halves ablated separately** (L-01: a redundant site makes a real defect
read as clean):

```
ablation                    still open    mid-upload handler
as shipped now              0/0/0/0       ends
release + emit removed      200/200/…     never ends
emit removed, release kept  0/0/0/0       never ends
```

So neither half masks the other.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**,
rpc_dart_http2 **+225 ~1** (the skip is B-53's narrow half).

## Not fixed

**A framing violation still counts toward nothing.** `_answerRejectedStream`
increments `_policyViolations` against the 256 backstop and honours
`closeOnProtocolError`; this site does neither, so a peer can grind out refused
frames on a connection indefinitely. Left alone deliberately: an over-limit
message is a RESOURCE_EXHAUSTED the sender can correct and retry, and counting
it as a protocol violation would close connections on legitimate clients that
merely misjudged a size limit. The `RpcStatus.internal` branch — genuinely
malformed framing — is the half that arguably should count, and separating them
is a behaviour decision. Filed as B-58.

Still uncovered from C-46: `validateMetadata` and content-type as refusal
triggers, and a peer that refuses to READ its own refusal.

## Links

- RPC-22 — the lens; `applied:` gains 397
- C-46 — round 395's negative, which named this site as undriven
- P-84 — extended with three arms, an `activeResponders` column and a canary
- B-58 — the backstop question this round did not answer
