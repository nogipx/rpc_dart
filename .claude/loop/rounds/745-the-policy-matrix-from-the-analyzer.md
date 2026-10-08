---
round: 745
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-08
bench: none
commit: yes
release: none
---

# Round 745 — the policy matrix, from the analyzer

## Target

RPC-08's detector is the matrix «policy field x transport». Its rounds have
probed it one field at a time. The analyzer lists every read of every
`RpcSecurityPolicy` field in one query per field, so the whole matrix can be
laid out at once and each empty cell explained.

## Hypothesis

A field that a transport must enforce for itself is read by one of http,
http2 and the channel transport (core), and not by another.

## Before

`find_references(RpcSecurityPolicy.<field>, scope lib)`, 18 fields. The
websocket, isolate and wasm transports read none of them directly; they are
`RpcChannelTransport` underneath. Who reads each field, comments excluded:

```
  field                               core            http          http2
  maxMessageLengthBytes               parser          caller, resp  caller, resp
  maxBufferedBytes                    parser          caller, resp  caller, resp
  maxMessagesPerChunk                 parser          -             caller, resp
  maxBufferedMessagesPerStream        pipeline        -             -
  maxActiveStreams                    channel         caller, resp  caller, resp, SETTINGS
  maxConcurrentHandlers               pipeline        -             -
  maxMetadataBytes                    frame channel   resp          caller, resp, server
  maxHeaders                          validate        -             common
  maxHeaderNameBytes                  validate        -             -
  maxHeaderValueBytes                 validate, trim  -             resp (trim)
  maxMethodPathLength                 validate        -             -
  closeOnProtocolError                channel         -             resp
  halfOpenStreamTimeout               pipeline        -             -
  flowControlWindowBytes              flow ctl        -             common
  flowControlConnectionWindowBytes    channel, pipe   -             -
  initialSendWindowBytes              flow ctl        -             -
  initialSendWindowGrace              flow ctl        -             -
  contentTypeValidation               pipeline        -             -
```

Each empty cell, explained:

- **Pipeline fields** (stream depth, handlers, half-open, content type, the
  connection budget) are read by `responder_pipeline.dart`, which sits on top
  of every transport.
- **`validateMetadata`** (headers, names, values, path) is called by every
  implementation in both roles: channel `:496 :786`, http caller `:238 :384`,
  http responder `:376 :575`, http2 caller `:911 :1532`, http2 responder
  `:604 :889`. Ten calls, from the same query.
- **The send-window fields** belong to `RpcFlowController`, rpc-level flow
  control. HTTP/2 uses its own; rounds 206–231 and 719–729 measured that path.
- **`maxMessagesPerChunk`** bounds HTTP/2 DATA frames that carry several gRPC
  messages. HTTP/1.1 parses one body per request.
- **`closeOnProtocolError`**: the field's own doc says it is honoured by the
  channel transports and the HTTP/2 responder, not by `rpc_dart_http`. The
  http2 CALLER does not read it on purpose (its comment, `rpc_http2_caller_
  transport.dart:1429`). The channel transport reads it in BOTH roles, so a
  websocket caller with the option set closes on a server's bad trailer and an
  http2 caller does not. The option is false by default, and the difference is
  documented. It is a decision, not a gap.

## Mechanism

None.

## After

n/a.

## Canary

n/a — no fix. The matrix is the instrument. It can see a missing read: the
reads it does report, for example http2's `maxActiveStreams` going out in
SETTINGS (`rpc_http2_responder_transport.dart:275`), are each a known
enforcement point.

## The verdict questions

1. n/a: a code census.
2. n/a.
3. In the analyzer's resolved references.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change.

## Not fixed

The `closeOnProtocolError` split between the websocket caller and the http2
caller. Whether a client should honour the option is the owner's call. The
http2 caller's comment states a position for clients that the channel
transport does not follow.

## Links

Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [..., 745]`.
