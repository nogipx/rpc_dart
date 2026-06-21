// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// Interface for RPC servers.
///
/// Defines a common contract for all kinds of RPC servers (HTTP/2, WebSocket,
/// gRPC, etc.). Used in [RpcServerBootstrap] to abstract over the concrete
/// transport implementation.
abstract interface class IRpcServer {
  /// Whether the server is running.
  bool get isRunning;

  /// Active RPC endpoints.
  List<RpcResponderEndpoint> get endpoints;

  /// Starts the server.
  Future<void> start();

  /// Stops the server.
  Future<void> stop();
}
