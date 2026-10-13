// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

/// Where a socket transport connects, or where a server listens.
///
/// Two kinds, one transport: the bytes on the wire are the same rpc_dart frame
/// protocol either way, and only the address family differs.
///
/// ```dart
/// const RpcSocketAddress.unix('/tmp/app/rpc.sock');
/// const RpcSocketAddress.tcp('127.0.0.1', 7000);
/// ```
sealed class RpcSocketAddress {
  const RpcSocketAddress();

  /// A Unix domain socket at [path].
  ///
  /// The OS caps the path: 104 bytes on macOS, 108 on Linux. Keep it short,
  /// and put it in a directory only the owner can enter, because whoever can
  /// connect to the socket file can make calls.
  const factory RpcSocketAddress.unix(String path) = RpcUnixSocketAddress;

  /// A TCP socket at [host] and [port].
  ///
  /// [host] is a `String` or an [InternetAddress], as for `ServerSocket.bind`.
  /// Port 0 on a server picks a free port; read it back from the server after
  /// it has started.
  const factory RpcSocketAddress.tcp(Object host, int port) =
      RpcTcpSocketAddress;

  /// The host argument for `Socket.connect` and `ServerSocket.bind`.
  Object get host;

  /// The port argument for `Socket.connect` and `ServerSocket.bind`.
  int get port;
}

/// A Unix domain socket address. See [RpcSocketAddress.unix].
final class RpcUnixSocketAddress extends RpcSocketAddress {
  /// Creates the address of the socket file at [path].
  const RpcUnixSocketAddress(this.path);

  /// The socket file.
  final String path;

  @override
  InternetAddress get host =>
      InternetAddress(path, type: InternetAddressType.unix);

  /// Always 0: a Unix socket has no port, and dart:io requires 0 for one.
  @override
  int get port => 0;

  @override
  String toString() => 'unix:$path';
}

/// A TCP socket address. See [RpcSocketAddress.tcp].
final class RpcTcpSocketAddress extends RpcSocketAddress {
  /// Creates the address [host]:[port].
  const RpcTcpSocketAddress(this.host, this.port);

  @override
  final Object host;

  @override
  final int port;

  @override
  String toString() {
    final h = host;
    return 'tcp:${h is InternetAddress ? h.address : h}:$port';
  }
}
