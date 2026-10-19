<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_socket

Unix domain socket and TCP transport for [`rpc_dart`](https://pub.dev/packages/rpc_dart)
on the Dart VM. It supports all four call kinds (unary, server stream, client
stream, bidirectional) over one connection.

Use it for local IPC between processes on one machine (a Unix socket), or for
a plain TCP link on a network you trust. This is the rpc_dart frame protocol
over a byte stream, not gRPC. Both peers must be rpc_dart with this package.

Contracts, endpoints, errors and `RpcSecurityPolicy` are documented in
`rpc_dart`. This README covers only what is specific to sockets.

## Install

```yaml
dependencies:
  rpc_dart_socket: ^0.1.0
```

VM only: it is built on `dart:io` sockets.

## Addresses

```dart
import 'dart:io';

import 'package:rpc_dart_socket/rpc_dart_socket.dart';

const unix = RpcSocketAddress.unix('/tmp/app/rpc.sock');
final tcp = RpcSocketAddress.tcp(InternetAddress.loopbackIPv4, 7000);
```

A Unix socket path is capped by the OS: 104 bytes on macOS, 108 on Linux. Put
it in a directory only its owner can enter, because whoever can connect to the
socket file can make calls.

## Server

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';

Future<RpcSocketServer> serve(RpcResponderContract contract) async {
  final server = RpcSocketServer.createWithContracts(
    address: const RpcSocketAddress.unix('/tmp/app/rpc.sock'),
    contracts: [contract],
  );
  await server.start();
  return server;
}
```

The server owns its listening socket: `start()` binds it, `stop()` closes it,
and a later `start()` binds again. `stop(drainTimeout: ...)` stops accepting,
lets running calls finish within the budget, then closes.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `policy` | `RpcSecurityPolicy()` | Limits applied to every connection. |
| `maxConnections` | none | Cap on concurrent connections, those still in their handshake included. A connection past it is closed at once. |
| `prefaceTimeout` | 10 s | How long an accepted socket may take to send its preface. No endpoint exists before it arrives. |
| `mode` | required | What each connection gets: `RpcResponderMode(register)` or `RpcPeerMode(register)` for peer mode, where both sides may start calls. The register adds the contracts. |
| `onConnectionOpened` / `onConnectionClosed` | none | Observability. Every opened connection is reported closed once. |

**A stale socket file is replaced.** A running server holds an exclusive lock
on `<path>.lock` beside its socket. `start()` takes that lock first and throws
a `SocketException` if a running server holds it, or if the lock file cannot be
created. With the lock taken, a socket file left by a server that crashed is
deleted when a connect to it is refused, and the bind is retried. A path that
is not a socket is left alone and `start()` throws. The lock belongs to the
process, so use one path per process. A clean `stop()` removes the socket file
and the lock file.

## Client

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';

Future<void> client() async {
  final transport = await connectRpcSocket(
    const RpcSocketAddress.unix('/tmp/app/rpc.sock'),
  );
  final endpoint = RpcCallerEndpoint(transport: transport);

  // ... make calls through a generated caller or the endpoint ...

  await endpoint.close(); // closes the transport and the socket
}
```

`connectRpcSocket` returns once the socket is connected. Calls can start at
once. `transport.ready` completes when the server's preface has arrived, which
is what tells an rpc_dart server apart from any other process listening there.

`connectTimeout` (30 s by default) bounds the whole open: the connect and the
server's preface. A failed connect throws an `RpcStatusException` with
UNAVAILABLE.

### Reconnect

The transport does not reconnect itself: a dropped socket closes it. For a
client that comes back, give `RpcClientConnection` from `rpc_dart` a factory
that calls `connectRpcSocket`. It builds a fresh transport per connection,
carries the stream id cursor across, and waits for `ready` before it reports
Online.

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';

RpcCallerEndpoint reconnectingCaller() {
  final connection = RpcClientConnection(
    transportFactory: () => connectRpcSocket(
      const RpcSocketAddress.unix('/tmp/app/rpc.sock'),
    ),
  );
  connection.connect();
  return RpcCallerEndpoint(transport: connection.transport);
}
```

Calls in flight when the socket drops are lost; reissue them once the
connection is Online again.

## The preface

The client writes eight bytes first, `rpcdart` and the frame protocol version,
and the server answers with the same eight before anything else. This is the
preface every rpc_dart channel transport opens with, see
`RpcChannelFrame.preface`. A bare socket otherwise says nothing about who
answered it. A peer that never speaks, or that speaks another protocol on the
same address, would look exactly like an idle server.

| Peer | `ready` and every call fail with |
| --- | --- |
| Closes or never sends a preface within the timeout | UNAVAILABLE |
| Sends `rpcdart` with another version | FAILED_PRECONDITION |
| Sends anything else | UNKNOWN |

The server's timeout is `prefaceTimeout` (10 s by default); the client's is
what is left of `connectTimeout`.

## Limits of a raw socket

- **No close reason.** A raw socket has no close code. A connection closed for a
  protocol violation reaches the peer as an ordinary end of stream, which its
  caller reports as UNAVAILABLE.
- **No keepalive.** A Unix socket cannot go half-open: the peer's death is an end
  of stream. A TCP path through a NAT or a load balancer can, and then a call on
  it hangs until its deadline. Give calls deadlines.
- **No TLS.** Use TCP only on a network you trust, or put the link inside one.
- **TCP_NODELAY is on** for TCP sockets: rpc_dart writes the frames of one
  event-loop turn together and then at once, and Nagle's algorithm would hold
  a small request back for a round trip.
