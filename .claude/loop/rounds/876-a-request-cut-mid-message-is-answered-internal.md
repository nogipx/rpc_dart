---
round: 876
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-25
bench: P-316 — reused
commit: yes
release: changelog
severity: S2 — "a status or error type a caller branches on"
---

# Round 876 — a request cut mid-message is answered INTERNAL

## Target

B-295, decided by the owner on 2026-10-16: a request stream that ends
inside a gRPC frame is answered INTERNAL on every shape and every
transport, as grpc-go answers it (`recvMsg` turns the cut into
`io.ErrUnexpectedEOF`, and `serverStream.RecvMsg` and `toRPCErr` map that
to `codes.Internal`). Three sites hold the status:
`unary/responder.dart` `answerIncompleteRequest`,
`base_processor_responder.dart` `_endRequests` (server, client, bidi), and
the http2 `_refuseIfEndedMidMessage`.

## Hypothesis

The three sites answer INVALID_ARGUMENT today; switching all three moves
every shape on every transport, because http, websocket, isolate and wasm
reach the core sites.

## Before

```
P-316 (http, round 847), "prefix promises 1 more" and "bare prefix":
  grpc=3 "Request stream closed mid-message" on echo, items, collect, chat
the core witnesses (unary_tolerates_a_fragmented_frame_test): status 3
the http2 witness (a_request_cut_mid_message_is_refused_test): '3'
```

## Mechanism

Each site wrote `RpcStatus.invalidArgument`. The unary site also answers
"no request message at all" (an empty payload frame, a bare half-close);
that one stays INVALID_ARGUMENT, so its status is chosen by `partial`.

The first switch broke `a_malformed_request_writes_no_log_line_test`: the
server-stream responder logs at `error` whenever `isFaultError` is true,
and a plain INTERNAL is a fault, so a peer sending a cut request wrote two
error records per call (20 calls, 40 records). `_endRequests` now raises
an `RpcPeerFaultException`, the existing marker for an error the peer
caused. It is still INTERNAL on the wire and is not logged as a fault.

## After

```
P-316 (http), the same rows: grpc=13 "Request stream closed mid-message"
  on echo, items, collect, chat; empty body stays grpc=3 (echo, items)
core witnesses: status 13 on unary (early and late half-close), server,
  client, bidi
http2 witness: '13' on all four shapes x data / empty data / trailers, and
  on collect and chat for a whole message plus the start of a second
the log test: 0 records for the unary and the server-stream cut
```

## Canary

All three sites switched off in place (`1 < 0 ? internal :
invalidArgument`, `1 < 0 && partial`): 22 rows red, e.g. `Expected: '13'
Actual: '3'` and `Expected: a string starting with 'status 13' Actual:
'status 3: Request stream closed mid-message ...'`. Restored: +54 green.
With `RpcPeerFaultException` replaced by `RpcStatusException`, the
server-stream log row fails with 40 records.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2243 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +620 ~152); `format:check` SUCCESS; `license:check` compliant.
The first gate run found two more tests that pinned the old status,
`a_request_cut_after_its_prefix_is_truncated_test` (client and bidi, 4
rows) and `unary_responder_parser_state_test`; both now expect 13.

## Siblings

- unary: `unary_tolerates_a_fragmented_frame_test` (two rows), and P-316 echo
- client: `unary_tolerates_a_fragmented_frame_test` client row, and P-316 collect
- server: `unary_tolerates_a_fragmented_frame_test` server row, the log test, and P-316 items
- bidirectional: `unary_tolerates_a_fragmented_frame_test` bidi row, and P-316 chat
- caller: read — the change is to the status a responder answers; the caller only reads it
- responder: the three sites above
- channel: the core witnesses run over `RpcChannelTransport`
- http: P-316, re-run above
- http2: `a_request_cut_mid_message_is_refused_test`
- websocket: read — a grep for the refusal text finds no site in its `lib/`; its responder is the core processors over `RpcChannelTransport`, changed here
- isolate: read — whole messages cross the port, so a request cannot end mid-frame; no site in its `lib/`
- wasm: read — no site in its `lib/`; the same core processors over a byte channel

## Not fixed

On http2, a unary or server-stream request holding one whole message and
the start of a second, ended on an empty DATA frame, is still answered OK.
The handler runs on the first message before the tail is seen. That is
B-292, decided and next.

## Links

Lead `../backlog/B-295-which-status-a-request-cut-mid-message-gets.md`.
Rounds `553-the-parser-knew-all-along.md`,
`554-one-rule-where-the-parser-is.md` and
`857-a-cut-http2-request-is-refused-with-cores-status.md` chose
INVALID_ARGUMENT; this reverses them. Lens
`../lenses/RPC-25-the-same-abstraction-four-times.md`.
