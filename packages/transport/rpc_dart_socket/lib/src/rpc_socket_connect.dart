// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_socket_address.dart';
import 'rpc_socket_caller_transport.dart';
import 'rpc_socket_channel.dart';

/// Connects to an rpc_dart socket server at [address] and returns the caller
/// transport.
///
/// Returns once the socket is connected; the server's preface may still be on
/// its way, and the transport's `ready` says when it has arrived. Calls can
/// start at once. Await `ready` to know that an rpc_dart server, and not some
/// other process, answered.
///
/// **No reconnect of its own.** A dropped socket closes the transport. For a
/// client that comes back, hand this function to `RpcClientConnection` as its
/// factory: it builds a fresh transport per connection, carries the stream id
/// cursor across, and waits for `ready` before it reports Online.
///
/// ```dart
/// final connection = RpcClientConnection(
///   transportFactory: () => connectRpcSocket(
///     const RpcSocketAddress.unix('/tmp/app/rpc.sock'),
///   ),
/// );
/// final caller = RpcCallerEndpoint(transport: connection.transport);
/// connection.connect();
/// ```
///
/// [connectTimeout] bounds the whole open, the socket connect and the
/// server's preface together: 30 s by default like the other callers, null
/// for no bound. A failed connect throws an [RpcStatusException] with
/// UNAVAILABLE: no call was made, so a later attempt may succeed. That covers
/// a missing socket file, a refused connection and the timeout alike. A
/// preface that fails later fails `ready` and every call; see
/// [RpcSocketChannel.ready]. An [Error] passes through unchanged.
///
/// TCP sockets get `TCP_NODELAY`: rpc_dart writes one frame per send, and
/// Nagle's algorithm would hold a small unary request back for a round trip.
///
/// **No keepalive.** A Unix socket cannot go half-open: the peer's death is an
/// end of stream. A TCP path through a NAT or a load balancer can, and then a
/// call on it hangs until its deadline; give calls deadlines.
Future<RpcSocketCallerTransport> connectRpcSocket(
  RpcSocketAddress address, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  Duration? connectTimeout = const Duration(seconds: 30),
  LogScope? logger,
}) async {
  final clock = Stopwatch()..start();
  final Socket socket;
  try {
    socket = await Socket.connect(
      address.host,
      address.port,
      timeout: connectTimeout,
    );
  } catch (e, st) {
    if (e is Error) rethrow;
    Error.throwWithStackTrace(
      RpcStatusException(
        RpcStatus.unavailable,
        'Socket connect to $address failed: $e',
      ),
      st,
    );
  }
  configureRpcSocket(socket, address);
  final left = connectTimeout == null ? null : connectTimeout - clock.elapsed;
  return RpcSocketCallerTransport(
    RpcSocketChannel(
      socket,
      prefaceTimeout: left == null || !left.isNegative ? left : Duration.zero,
    ),
    policy: policy,
    logger: logger,
  );
}

/// Socket options both ends apply. Internal to this package.
void configureRpcSocket(Socket socket, RpcSocketAddress address) {
  // Unix sockets refuse TCP options with EOPNOTSUPP.
  if (address is! RpcTcpSocketAddress) return;
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } on SocketException {
    // The peer already hung up; the read side will report it.
  }
}
