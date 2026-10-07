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
| `RpcChannelTransport.fromChannel({required channel, required isClient, policy, resumeStreamIdsAfter, logger})` | Wraps a raw `IRpcChannel` (bytes in, bytes out) with rpc_dart framing, multiplexing, flow control and policy checks. Build one per side. |

`RpcInMemoryTransport` is deprecated; use `RpcChannelTransport.memoryPair()`.
`policy` is an `RpcSecurityPolicy` (see `security-and-flow-control.md`).

```dart
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

- `IRpcReconnectableTransport` is an `IRpcTransport` that also exposes its
  stream-id cursor (`lastIssuedStreamId`, `resumeStreamIdsAfter`). A replacement
  transport resumes ids after the old one, so late frames from dead calls never
  land on new calls. `RpcChannelTransport` and the http, http2, websocket,
  isolate and wasm caller transports implement it.
- `endpoint.reconnect()` asks the transport to reconnect and returns an
  `RpcEndpointHealth` (`endpointStatus`, `dependencies['transport']`). It never
  throws: an unsupported or failed reconnect comes back as a degraded or
  unhealthy status. `RpcChannelTransport.reconnect()` does not reconnect (it
  reports `degraded` with `supported: false`); build a new transport instead.
- For automatic reconnect with backoff, wrap a transport factory in
  `RpcClientConnection(transportFactory: ...)` (it requires a factory returning
  `IRpcReconnectableTransport`), call `connect()`, and give
  `connection.transport` to a single `RpcCallerEndpoint` that you keep for the
  app's lifetime. See `errors-and-resilience.md`.
- In-flight calls do not survive a reconnect. Only new calls do; reissue the
  lost ones yourself (idempotent methods only).

```dart
Future<bool> tryReconnect(RpcCallerEndpoint endpoint) async {
  final report = await endpoint.reconnect();
  return report.endpointStatus.level == RpcHealthLevel.healthy;
}

RpcCallerEndpoint resilientCaller(
  Future<IRpcReconnectableTransport> Function() connectTransport,
) {
  final connection = RpcClientConnection(transportFactory: connectTransport)
    ..connect();
  return RpcCallerEndpoint(transport: connection.transport);
}
```

## Pitfalls

- `RpcChannelTransport.pair()` is not zero-copy. Zero-copy methods (no codecs)
  fail on it; use `memoryPair()` for those, or add codecs.
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
- A transport decorator that forwards `IRpcTransport` but not the
  `IRpcReconnectableTransport` members loses reconnect safety; implement the
  capability interfaces it wraps.
