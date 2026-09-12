---
status: open
round: 354
commit: 3a827426
paths: [packages/core/rpc_dart/lib/src/integration/rpc_server_interface.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/drain_in_peer_mode.dart
reason: "a breaking change to a published interface across three packages, for a getter whose only in-repo readers are tests — the type is the obstacle, not the logic, so it is a design decision rather than a repair"
---

# B-37 — `RpcWebSocketServer.endpoints` is always empty in peer mode

## What the code does

```dart
@override
List<RpcResponderEndpoint> get endpoints =>
    List.unmodifiable(_endpoints.whereType<RpcResponderEndpoint>());
```

`_endpoints` is `List<RpcEndpointBase>` and holds both kinds — deliberately, and
the field's own comment says why: narrowing it *"drops peer endpoints out of
`stop`, which closes what it finds here"*. The GETTER then narrows anyway, so a
server built with `onPeerEndpointCreated` reports zero endpoints however many
connections it is serving.

`stop()` is unaffected: it iterates `_endpoints`, not this getter. What is
affected is anyone asking the server what it is serving.

## Why it is a lead and not this round's fix

The return type is fixed by the shared interface:

```dart
// packages/core/rpc_dart/lib/src/integration/rpc_server_interface.dart:20
List<RpcResponderEndpoint> get endpoints;
```

`RpcHttpServer` and `RpcHttp2Server` implement it too, and neither has a peer
mode — http2's `_endpoints` is itself `List<RpcResponderEndpoint>`. So widening
the getter means widening the interface to `List<RpcEndpointBase>`, which is a
breaking change for any external implementor or caller, in a published package,
to fix a getter whose only readers inside this repository are tests.

`RpcPeerEndpoint` and `RpcResponderEndpoint` are sibling subclasses of
`RpcEndpointBase`, not one a subtype of the other, so there is no narrower type
that covers both.

## Owner decision

**Not yet taken, and one is needed before anything is built.** Three options,
and they differ in what the API promises callers rather than in any number:

1. Widen `IRpcServer.endpoints` to `List<RpcEndpointBase>` — honest, breaking
   for any external implementor or caller, and it makes every caller handle a
   type that may not serve calls at all.
2. Add a second getter (`peerEndpoints`, or `allEndpoints`) — additive and
   non-breaking, and it leaves `endpoints` silently lying for one of the two
   modes.
3. Leave it, and document that `endpoints` means responder-mode endpoints.

Round 354 makes no recommendation. Nothing measurable separates them: the drain,
which is what the defect actually broke, is fixed and does not use this getter.

## Guarded by

Nothing yet — there is no test asserting the getter's contents in peer mode,
because what it SHOULD contain is the open question.
