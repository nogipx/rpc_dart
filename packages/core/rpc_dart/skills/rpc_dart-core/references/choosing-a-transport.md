<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Choosing a transport

Every transport implements `IRpcTransport`. Contracts and endpoints do not
change with the transport: pass the transport to `RpcCallerEndpoint`,
`RpcResponderEndpoint` or `RpcPeerEndpoint` and the rest of the code is the
same. Only core's in-process transport lives in `rpc_dart`; the others are
separate packages.

## Rules

- Each side of a connection has one transport. The client side has
  `isClient == true` (opens odd stream ids), the server side `false` (even ids).
  `RpcCallerEndpoint` requires a client transport, `RpcResponderEndpoint` a
  server transport; `RpcPeerEndpoint` takes either, but the two ends must differ.
- Pick the transport by who must be able to talk to you, then by platform.
  Construction, server setup and options are in each package's README; this
  file does not repeat them.
- Network transports have `supportsZeroCopy == false`: every method needs both
  codecs (see `codecs-and-compression.md`).
- Closing an endpoint closes its transport.

## Decision table

| Need | Use | Package | Wire | Platforms | Shapes | Zero-copy |
| --- | --- | --- | --- | --- | --- | --- |
| Same isolate: tests, modular monolith | `RpcChannelTransport.memoryPair()` | `rpc_dart` | none (objects) | all | all four | yes |
| Interop with gRPC clients/servers in any language | HTTP/2 caller/responder + server | `rpc_dart_http2` | real gRPC over HTTP/2 | VM (caller and server) | all four | no |
| Plain HTTP/1.1, proxies, browser `fetch` | HTTP caller/responder + server | `rpc_dart_http` | one HTTP request per call | caller: VM and web; responder/server: VM | **unary only** | no |
| Browser or app talking to a Dart server, streaming | WebSocket caller/responder + server | `rpc_dart_websocket` | rpc_dart frame protocol (both ends must be rpc_dart) | caller: VM and web; server: VM | all four | no |
| Offload work to another isolate / web worker | isolate transport | `rpc_dart_isolate` | `SendPort` messages (VM), worker messages (web) | VM and web | all four | VM: yes; web: no |
| Run a WebAssembly guest module from Flutter | wasm bridge transport | `rpc_dart_wasm` (Flutter plugin) | rpc_dart frames over a byte bridge | Flutter iOS/Android, browser | all four | no |
| Your own byte pipe (TCP, serial, custom socket) | `RpcChannelTransport.fromChannel(channel:, isClient:)` | `rpc_dart` | rpc_dart frame protocol | any | all four | no |

Notes:

- gRPC interop exists only on `rpc_dart_http2`. The WebSocket, wasm and
  `fromChannel` transports speak rpc_dart's own framing, not gRPC.
- Web clients: `rpc_dart_websocket` for streaming, `rpc_dart_http` for unary.
  Neither server side runs in a browser.
- For server bootstraps (`IRpcServer` implementations in the transport
  packages), each accepted connection gets its own `RpcResponderEndpoint`, so a
  responder contract's `dispose()` runs per connection.

## Core transports

| Factory | Use |
| --- | --- |
| `RpcChannelTransport.memoryPair({policy})` | Returns `(client, server)`. Objects passed by reference, `supportsZeroCopy == true`. Default for in-process use and unit tests. |
| `RpcChannelTransport.pair({policy})` | Returns `(client, server)`. In memory but encodes real frames, `supportsZeroCopy == false`. Use in tests to exercise codecs, compression and frame limits as a network transport would. |
| `RpcChannelTransport.fromChannel({required channel, required isClient, policy, resumeStreamIdsAfter, ready, logger})` | Wraps a raw `IRpcChannel` (bytes in, bytes out) with rpc_dart framing, multiplexing, flow control and policy checks. Build one per side. `ready` is the channel's own readiness when it is still connecting. |

`policy` is an `RpcSecurityPolicy` (see `security-and-flow-control.md`).

`IRpcChannel` and the other transport-authoring types (frames, the message
parser, the flow-control interfaces, `RpcTrailers`, `RpcConnectionHost`,
`RpcWriteBacklog`, `RpcWriteCoalescer`) are not in `rpc_dart.dart`. Import
`package:rpc_dart/transport.dart`, which re-exports `rpc_dart.dart`. The
`dart:io`-only `RpcHeaderBoundedServerSocket` is in
`package:rpc_dart/transport_io.dart`.

```dart
import 'package:rpc_dart/transport.dart';

Future<void> inProcess() async {
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
  final server = RpcResponderEndpoint(transport: serverTransport)..start();
  final client = RpcCallerEndpoint(transport: clientTransport);
  // Register contracts on `server`, bind caller contracts to `client`.
  await client.close();
  await server.close();
}

/// Same API, but frames are really encoded: codecs are mandatory.
(RpcCallerEndpoint, RpcResponderEndpoint) framedForTests() {
  final (clientTransport, serverTransport) = RpcChannelTransport.pair();
  return (
    RpcCallerEndpoint(transport: clientTransport),
    RpcResponderEndpoint(transport: serverTransport),
  );
}

RpcCallerEndpoint overCustomPipe(IRpcChannel channel) => RpcCallerEndpoint(
  transport: RpcChannelTransport.fromChannel(channel: channel, isClient: true),
);
```

## Reconnecting

- A transport is one connection. When the connection is lost the transport
  closes, and its `incomingMessages` ends; no transport reconnects itself.
- `RpcClientConnection(transportFactory: ...)` is the one layer that
  reconnects: it builds a new transport from the factory after each drop, with
  backoff. Call `connect()` and give `connection.transport` to a single
  endpoint that you keep for the app's lifetime. See
  `errors-and-resilience.md`.
- Every `IRpcTransport` carries its stream-id cursor (`lastIssuedStreamId`,
  `resumeStreamIdsAfter`). The connection resumes the new transport's ids after
  the old one's, so late frames from dead calls never land on new calls. In
  peer mode it also ends the calls the peer had opened on the lost connection.
- In-flight calls do not survive a reconnect. Only new calls do; reissue the
  lost ones yourself (idempotent methods only).

```dart
RpcCallerEndpoint resilientCaller(
  Future<IRpcTransport> Function() connectTransport,
) {
  final connection = RpcClientConnection(transportFactory: connectTransport)
    ..connect();
  return RpcCallerEndpoint(transport: connection.transport);
}
```

## Pitfalls

- `RpcChannelTransport.pair()` is not zero-copy. A responder on it refuses to
  register a contract with zero-copy methods (no codecs), and a caller's
  zero-copy call throws; use `memoryPair()` for those, or add codecs.
- Tests on `memoryPair()` alone hide codec bugs: unary calls there skip codecs
  under the default `auto` mode. Run at least one test on `pair()` or a real
  transport.
- `rpc_dart_http` is for unary. Streaming methods do not fail there, they
  degrade: the whole response arrives only after the handler finishes, and an
  unbounded stream never returns. Use http2, websocket or isolate for streams.
- WebSocket, wasm and `fromChannel` peers must both be rpc_dart; a gRPC client
  cannot call them.
- Do not create a new `RpcCallerEndpoint` per reconnect when using
  `RpcClientConnection`; its transport proxy is stable.
- A transport decorator `implements IRpcTransport` and forwards every member,
  the optional ones included (`securityPolicy`, `ready`, `resetStream`,
  `flowCredit`, `grantsMessageCredit`, `connectionBuffer`, the stream-id
  cursor). The compiler insists; a decorator that `extends` instead silently
  inherits the defaults for what it does not override.
- A custom transport must close when its connection is lost. One that stays
  open leaves `RpcClientConnection` online over a dead connection.
