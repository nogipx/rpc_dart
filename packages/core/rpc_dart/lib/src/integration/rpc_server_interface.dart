// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../_internal.dart';

/// Interface for RPC servers.
///
/// Defines a common contract for all kinds of RPC servers (HTTP/2, WebSocket,
/// gRPC, etc.). Used in [RpcServerBootstrap] to abstract over the concrete
/// transport implementation.
abstract interface class IRpcServer {
  /// Whether the server is running.
  bool get isRunning;

  /// Active RESPONDER endpoints, and only those.
  ///
  /// **Empty on a server running in peer mode**, where each connection gets an
  /// [RpcPeerEndpoint] instead — that type serves calls too, but it is not an
  /// [RpcResponderEndpoint] and cannot appear here. So an empty list means
  /// "none of this kind", never "no connections": do not read it as a liveness
  /// or connection count.
  ///
  /// The type is deliberate rather than an oversight. Widening it would break
  /// every external implementor and hand callers something that may not serve
  /// calls at all, and a second getter would leave this one quietly lying in
  /// one of the two modes. A server that needs both exposes them itself.
  List<RpcResponderEndpoint> get endpoints;

  /// Starts the server.
  Future<void> start();

  /// Stops the server.
  Future<void> stop();
}
