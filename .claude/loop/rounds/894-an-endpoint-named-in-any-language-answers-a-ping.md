---
round: 894
verdict: FIXED
packages: [rpc_dart]
lens: RPC-02
bench: P-346 — new
commit: yes
severity: S1 — "a documented or default setup that does not work at all"
release: changelog
---

# Round 894 — an endpoint named in any language answers a ping

## Target

The class of round 893 swept (L-12): a header value the LIBRARY builds from
text it does not control, sent through a hop that validates it. A text sweep
of every `RpcHeader(` with a non-constant value in core and transport `lib/`
found 16; all but one carry a status, a number, an encoding name, a header the
peer or the application sent and owns, or a value already checked
(`statusOnly`). The one: `RpcResponderPingHandler` puts the endpoint's
`debugLabel` raw into `x-rpc-pong-endpoint`.

## Hypothesis

`debugLabel` is an `RpcResponderEndpoint` constructor parameter with no stated
restriction, so a name in another language, or a long one, makes the pong's
header fail the policy, and every ping to that endpoint fails. Fails if the
ping answers.

## Before

P-346 (`r894_ping_label/probe.dart`):

```
control  debugLabel "orders"            ok
control  no debugLabel                  ok
arm      debugLabel "Сервер заказов"    RpcStatusException(3): Invalid metadata header value for: x-rpc-pong-endpoint
arm      debugLabel 10000 x "a"         the same
```

## Mechanism

RPC-02, the round-893 shape: advisory text in a header that carries a
required answer, so the text's validity decides whether there is an answer.
Anything that watches health by ping reads such a server as down.

## After

The handler percent-encodes the label with `RpcMetadata.encodeGrpcMessage`
and leaves the header out when even the encoded label fails the transport's
`isValidHeaderValue`; `RpcEndpointPingExchange` decodes it into
`responderDebugLabel`. Plain labels are unchanged on the wire ("srv" in
`endpoint_responder_registry_and_ping_handler_test.dart` still reads "srv").
P-346 after: all four ok. The skill's ping paragraph says so.

## Canary

`a_ping_answers_whatever_the_endpoint_is_called_test.dart`:
1. encoding off: "an endpoint named in another language answers a ping" red,
   "Expected: 'Сервер заказов' Actual: <null>" -- the ping answered, because
   the policy check left the raw label out: that half MASKS the encoding's
   absence for the ping (L-01), and the text is what witnesses it.
2. decoding off: the same test red with the percent-encoded label.
3. the policy check off: "a name past the header limit is left out, the ping
   answers" red, `RpcStatusException(3): Invalid metadata header value for:
   x-rpc-pong-endpoint` (policy `maxHeaderValueBytes: 64`, a 200-character
   name).
Restored: all green.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`, `api:check`, `test:web`: green. `test/endpoint` and the pinned
wire test: `+415`; the witness under `-p node`: `+3`. No public API change.

## Siblings

- responder: fixed here (`responder_ping_handler.dart` encodes).
- caller: fixed here (`ping.dart` decodes).
- The ping is one exchange on every transport; no transport builds this
  header.

## Not fixed

—

## Links

Round 893, RPC-02, L-01, L-12, P-346.
