---
status: open
round: 339
commit: e63e551b
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/outbound_metadata_unvalidated.dart
reason: "measured and parked, not deferred — round 339 had started on it when a CI failure arrived and took the round; the measurement is complete enough to act on and is filed so it is not re-derived"
---

# B-34 — http2 is the only transport that does not check outbound metadata

Found by applying RPC-10 — *which packages ACTUALLY go through the class that
changed?* — to `RpcChannelTransport.sendMetadata`, which calls
`_policy.validateMetadata(metadata)` before handing anything to the channel.

## The map, verified on the current tree

```
transport                                   outbound sendMetadata validates?
RpcChannelTransport (websocket, wasm,       YES  channel_transport.dart:440
                     isolate)
rpc_dart_http caller / responder            YES  :291 / :416
rpc_dart_http2 caller / responder           NO   its only validateMetadata is
                                                 inbound (:1241, :466)
```

http2 is not unchecked: `rpc_http2_common.dart:540`'s `_headerValue` rejects
non-printable-ASCII, and the first arm of the probe confirms both arms refuse a
Cyrillic header value. But a hardcoded charset check is not a policy — it does
not know `maxHeaders`, `maxHeaderValueBytes`, `isValidHeaderName` or
`isValidMethodPath`.

## Measured

`sendMetadata` driven directly (public `IRpcTransport` API) under
`RpcSecurityPolicy(maxHeaders: 32, maxHeaderValueBytes: 64)`:

```
                            shared layer                       http2
64 headers (max 32)         ArgumentError: Too many...         ACCEPTED
value 200 chars (max 64)    ArgumentError: Invalid value...    ACCEPTED
header name with a space    ArgumentError: Invalid name...     ACCEPTED
```

**The blast radius is one stream, and that is why this is a lead and not a
round.** A clean call before and after each violation returns `ok(x)`: the frame
goes out, the peer's inbound check refuses that stream, and nothing else on the
connection is harmed.

> A first pass used `maxHeaders: 4` and read as if the violating frame poisoned
> the connection — every later call failed. It did not: 4 is below what an
> ordinary request carries, so the peer was refusing *every* call, including the
> control. The "before" arm is what caught it.

## The fix, and the one question in it

Two lines — `_policy.validateMetadata(metadata)` at the top of each http2
`sendMetadata`, exactly as the HTTP/1.1 caller does.

The question worth a moment: outbound validation refuses against the SENDER's
policy, while today the same message is refused against the PEER's. For an
asymmetric deployment those differ, so a sender could start refusing something
its peer would have accepted. `RpcChannelTransport` and `rpc_dart_http` already
make that choice, so applying it to http2 is consistency rather than a new
policy — but it is a behaviour change on a published transport and deserves to
be stated rather than slipped in.

## Owner decision

**None taken, and none needed to proceed.** This is not deferred on risk or
cost: it is parked because a CI failure arrived mid-round and took round 339.
The two-line fix matches what four of five transports already do. The only thing
worth the owner's eye is the sender-policy-versus-peer-policy note above, and
only if rpc_dart is deployed with asymmetric policies on the two ends.
