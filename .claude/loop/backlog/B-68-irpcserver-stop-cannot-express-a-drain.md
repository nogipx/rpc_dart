---
status: closed (round 418)
round: 418
commit: ff930001
paths: [packages/core/rpc_dart/lib/src/integration/rpc_server_interface.dart, packages/core/rpc_dart_framework/lib/src/rpc_app.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: none — READ, not measured
reason: cost — widening an interface every external implementor implements is a breaking change, so it waits for the owner's call on whether it goes in the next major
---

# B-68 — `IRpcServer.stop()` cannot express a drain, so `RpcApp` never asks for one

Two of the three servers implement a graceful stop:

```dart
Future<void> stop({Duration? drainTimeout}) async { ... }
  rpc_http2_server.dart:456
  rpc_http_server.dart:275
```

The interface they satisfy does not have the parameter:

```dart
Future<void> stop();          // rpc_server_interface.dart:37
```

`RpcApp` holds an `IRpcServer`, so the widened signature is unreachable from it.
`rpc_app.dart:200` calls `await _server?.stop()` — the narrow one, no drain
timeout, which is a hard stop.

## What `RpcApp` does instead, and why it is the wrong half

It drains itself first: `stop()` at `rpc_app.dart:170` calls `_drainEndpoints()`
at `:176`, which runs `ep.drain(timeout: _config.drainTimeout)` for every
endpoint (`:428`) before reaching the server at `:200`.

Two things are wrong with that order.

**It drains while the listener is still accepting.** Nothing has told the server
to stop admitting connections at `:176`, so a connection arriving during the
drain window gets an endpoint that is already draining.

**`endpoint.drain()` is the heavier of the two operations and it cancels
contexts.** The websocket server knows this and says so in a comment at
`rpc_websocket_server.dart:215`, which is why it calls `markDraining()` and not
`drain()`. `RpcApp` calls the one that comment warns against.

## `markDraining()` has exactly one caller

```
  base_endpoint.dart:36          void markDraining() {}        no-op base
  responder_pipeline.dart:489    _respIsDraining = true        the real one
  rpc_websocket_server.dart:219  the ONLY call site
```

So "stop admitting, let what is in flight finish" exists, is correct, and is
reachable from one of the three servers. The http2 and http servers do not call
it; `RpcApp` cannot.

## Relationship to B-63

B-63 #2 and #3 are about the two servers holding byte-identical copies of
`_inFlightCalls()` and `_notify`. **This is a different claim and does not
overlap**: those copies agree with each other and the risk is future drift; this
one is a capability that exists in one server and is unreachable from the
framework. A round could take both together — they are the same two files — but
closing one does not close the other.

## Why it waits

`IRpcServer` is a public `abstract interface class` and every external
implementor implements `stop()`. Adding an optional named parameter to an
interface method is a breaking change for implementors, so the shape of the fix
(widen `stop`, or add a separate `drain()` to the interface, or give
`RpcApp` a narrower typed hook) is the owner's call. Ordinary scope note: this
is about the code, not the release — see config's "Out of scope".

## Owner decision

**"Backward compatibility does not matter."** The interface widens.

## Closed — round 418

`IRpcServer.stop({Duration? drainTimeout})`. All three first-party servers
already had the signature, so nothing changed there.

**The real fix was the ORDER, not the parameter.** `RpcApp` now asks the SERVER
to drain and does it FIRST — before `module.onStop()` — so a handler finishing
in the window can still reach what its module owns. `_drainEndpoints` is gone
with its two wrong-order problems: draining endpoints while the listener was
still accepting, and using `RpcEndpointBase.drain`, which CANCELS active
contexts.

**The breaking cost, measured: six test fakes in `rpc_dart_framework`** implement
`IRpcServer` and each needed the new parameter. Confined to one package.

**A residual, stated rather than discovered later**: `RpcApp` no longer calls
`endpoint.drain()` at all, so a third-party `IRpcServer` that accepts
`drainTimeout` and ignores it now silently gets no drain, where the app used to
compensate.
