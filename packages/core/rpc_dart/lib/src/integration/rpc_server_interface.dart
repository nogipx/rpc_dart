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
abstract class IRpcServer {
  /// Whether the server is running.
  bool get isRunning;

  /// The endpoint of every live connection, in either mode: an
  /// [RpcPeerEndpoint] is an [RpcResponderEndpoint] that can also start calls.
  List<RpcResponderEndpoint> get endpoints;

  /// Starts the server.
  Future<void> start();

  /// Stops the server, optionally draining first.
  ///
  /// With a [drainTimeout] the server STOPS ADMITTING and lets what is in
  /// flight finish, up to that budget, before closing. Without one it closes
  /// immediately.
  ///
  /// **The parameter is on the interface because the drain cannot be done from
  /// outside.** Two of the three first-party servers already took it and the
  /// interface did not, so a caller holding an `IRpcServer` could only reach
  /// the hard stop — and the one caller that wanted a graceful shutdown
  /// compensated by draining the endpoints itself, which gets the order wrong
  /// twice: nothing has stopped the LISTENER, so a connection arriving
  /// mid-window gets an already-draining endpoint, and `RpcEndpointBase.drain`
  /// is the heavier operation that CANCELS active contexts — the opposite of
  /// letting in-flight work finish.
  Future<void> stop({Duration? drainTimeout});
}
