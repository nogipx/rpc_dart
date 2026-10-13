// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Unix domain socket and TCP transport for rpc_dart on the Dart VM.
///
/// [connectRpcSocket] opens an [RpcSocketCallerTransport], [RpcSocketServer]
/// serves contracts, [RpcSocketAddress] names either kind of socket, and
/// [RpcSocketChannel] is the raw byte channel both are built on.
library;

export 'src/rpc_socket_address.dart';
export 'src/rpc_socket_caller_transport.dart';
export 'src/rpc_socket_channel.dart';
export 'src/rpc_socket_connect.dart' show connectRpcSocket;
export 'src/rpc_socket_server.dart';
