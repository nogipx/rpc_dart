---
round: 893
verdict: FIXED
packages: [rpc_dart]
lens: RPC-02
bench: P-345 — new
commit: yes
severity: S1 — "a call, connection or shutdown that hangs with no bound"
release: changelog
---

# Round 893 — a cancel reason in any language reaches the server

## Target

Lens RPC-02 (rank 2), swept last in round 869; its detector named
`RpcMetadata.forTrailer`, which `0ac48621` removed in favour of
`RpcTrailers`, so the surface had moved under it. Re-swept over the
`RpcTrailers` builders (`status`, `of`, `forError`, `fromHttpStatus`,
`unexpectedContentType`, `cancelled`): every one that carries a message caps
it through `status`'s `maxMessageLength` except `cancelled(reason)`, which put
its `reason` raw into `x-rpc-cancellation-reason`.

## Hypothesis

On every transport whose `resetStream` is the default `false` -- all but
http2 -- a caller's cancel is a metadata notice built by
`RpcTrailers.cancelled(token.reason)`. The reason is the application's text.
A header value must be printable ASCII within `maxHeaderValueBytes`, so a
reason in another language, or a long one, gets the notice refused at
`sendMetadata`; `_notifyPeerOfCancellation` logs and swallows that, and the
server never learns the call was cancelled. Fails if the server's handler is
cancelled anyway.

## Before

P-345 (`r893_cancel_reason/probe.dart`), in-memory pair, a ticking server
stream, the caller's token cancelled 1 s before the read:

```
control  "user cancelled"           server saw the cancel
arm      "Пользователь отменил"     server still running at 1 s
arm      10000 x "x"                server still running at 1 s
```

Matrix, the new I-6 row (below) with both halves of the fix off: channel,
isolate, socket and websocket red, "the handler of call 1 never reported
\"cancelled\" within 1000 ms (the caller cancelled with a non-ASCII reason)";
http2 green (RST_STREAM carries the cancel).

## Mechanism

RPC-02: a synthetic notice that the policy it travels under refuses. The
policy's own doc says human-readable text in any language belongs in the
percent-encoded `grpc-message`; the cancellation reason never got that
treatment. For a subscription (server stream, bidi) the server's call then
runs until the connection closes.

## After

- `RpcTrailers.cancelled` percent-encodes the reason with
  `RpcMetadata.encodeGrpcMessage` (its default length cap). A reason of
  unreserved characters is unchanged on the wire, so the pinned
  `cancelled('bye')` still reads `x-rpc-cancellation-reason=bye`.
- The responder decodes it with `RpcMetadata.decodeGrpcMessage`, so the
  handler's token carries the caller's text.
- `_notifyPeerOfCancellation` checks the encoded reason against the
  transport's `isValidHeaderValue` and, past it (a policy with a small
  `maxHeaderValueBytes`), sends "Cancelled by client" instead: the reason is
  advisory, the notice is not.

P-345 after: all three arms "saw the cancel". Matrix row: 4 of 4 measured
notice members green (were red).

No public signature changed (`api:check` green). The skill's reserved-header
row says the reason is percent-encoded.

## Canary

`a_cancel_reason_in_any_language_reaches_the_server_test.dart`:
1. encoding off: "a reason in another language reaches the server intact"
   red, "Expected: 'Пользователь отменил' Actual: 'Cancelled by client'" --
   the fallback still delivered the cancel, so the fallback MASKS the
   encoding's absence for reach (L-01); the text is what witnesses it.
2. decoding off: the same test red with the percent-encoded text, and the
   GUARD "a plain ASCII reason arrives as it was sent" red with
   "user%20cancelled".
3. fallback off: "a reason past the header limit still cancels the server"
   red, "Expected: not null Actual: <null> the over-long reason got the whole
   notice refused" (policy `maxHeaderValueBytes: 64`, a 200-character reason).

Matrix, encoding and fallback both off: the four members above red; both on:
`+5 ~2` (http known-failing on macOS, wasm outside the workspace). Restored:
all green.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`, `api:check`, `test:web`: green. The witness and the pinned
wire test under `-p node`: `+13`.

## Siblings

- channel: fixed here, matrix row green (red before).
- websocket: fixed here, matrix row green (red before).
- isolate: fixed here, matrix row green (red before).
- wasm: n/a here — outside the workspace, the row is skipped; it uses the
  same caller path and the same notice.
- http2: clean — `i6_cancel_reaches_responder_test.dart`, row "unary,
  cancelled with a reason in another language", green with both halves of
  the fix off: `resetStream` sends RST_STREAM and no notice.
- http: read — `RpcHttpCallerTransport` has no `resetStream` override, but
  HTTP/1.1 carries a cancel as the TCP close, not as this notice; the matrix
  row is known-failing on macOS for that close's latency (B-284) and was not
  measured here.
- caller: fixed here (`base_processor_caller.dart`).
- responder: fixed here (`responder_pipeline_dispatch.dart` decodes).
- (not a group member) socket: fixed here, matrix row green (red before).

## Not fixed

—

## Links

RPC-02, I-6, L-01, round 869, `0ac48621`, P-345.
