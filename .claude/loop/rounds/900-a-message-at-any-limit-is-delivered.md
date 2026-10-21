---
round: 900
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2, rpc_dart_socket, rpc_dart_websocket, rpc_dart_isolate]
lens: RPC-08
bench: P-352 — new
commit: yes
release: none
---

# Round 900 — a message at any limit is delivered

## Target

RPC-08 (rank 25, 29 FIXED of 41, last applied in round 801): a policy field
honoured on one transport. A reading of every `RpcSecurityPolicy` field's
readers found each enforced where its dartdoc says, so the round measured the
one field whose matrix is pinned to a single value: I-2 sends exactly the
DEFAULT `maxMessageLengthBytes`, and round 898 showed what a single point in a
matrix can hide.

## Hypothesis

At a limit other than the default, or with the two sides on different
limits, some transport refuses or mangles a message the receiver's policy
admits. Fails if every member delivers at every limit, and treats a
mismatch the same way.

## Before

P-352:

```
same limit both sides, exact-size message, 4 shapes x 6 members
  64 KiB   delivered 24/24
  16 MiB   delivered 24/24
  32 MiB   delivered 24/24

receiver 32 MiB, sender default, 20 MiB message
  request    delivered on all six members
  response   delivered on channel, http2, isolate, socket, websocket
             http: status 8 "Response exceeds the 16777216-byte limit;
             HTTP/1.1 cannot stream it", all four shapes
```

## Mechanism

n/a (CLEAN). The http responder holds a whole response before it can send
it, so it bounds the response by its own `effectiveMaxBufferedBytes`
(`rpc_http_responder_transport.dart`, `sendMessage`). That is HTTP/1.1's
buffering, which the package README states ("The whole stream must fit in
one body ... bounded by `maxBufferedBytes`"); every other transport streams
and leaves the bound to the receiver.

## After

No behaviour change. The S3 text found on the way is corrected in the same
commit: the http README's "Limits" now says the responder's
`maxBufferedBytes` bounds a response too; the comment above the check no
longer rests on the caller sharing the policy; and the refusal names the
bound it checks. P-352's mismatch arm after: "Response exceeds the
16777221-byte limit" (before: 16777216, the message limit without the frame
prefix).

## Canary

n/a (CLEAN). The 16 MiB row is I-2's own and green; the http refusal is the
method seeing a refusal.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`; rpc_dart_http alone `+257`.

## Siblings

- websocket: clean — P-352.
- http: clean — P-352; the response bound is the documented HTTP/1.1 one.
- http2: clean — P-352.
- isolate: clean — P-352.
- wasm: n/a — not runnable outside `test:wasm`; its bridge has no limit of
  its own beside the frame channel's.
- channel: clean — P-352.
- caller: clean — P-352's request direction.
- responder: clean — P-352's response direction.
- (not a group member) socket: clean — P-352.

## Not fixed

The behaviour itself: HTTP/1.1 has to buffer, so the responder's bound
stays.

## Links

RPC-08, I-2, round 898, P-352.
