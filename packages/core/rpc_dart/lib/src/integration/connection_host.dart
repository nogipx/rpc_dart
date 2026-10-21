// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../contracts/_index.dart';
import '../core/_index.dart';
import '../endpoint/_index.dart';
import '../logger/_index.dart';
import 'drain.dart';

/// What a server builds for each connection, and how the application's
/// contracts get onto it.
sealed class RpcServerMode {
  const RpcServerMode();
}

/// Each connection gets an [RpcResponderEndpoint]; only the client starts
/// calls.
final class RpcResponderMode extends RpcServerMode {
  /// [register] registers the contracts on each connection's endpoint.
  const RpcResponderMode(this.register);

  /// A mode that registers [contracts] on every connection.
  RpcResponderMode.contracts(List<RpcResponderContract> contracts)
    : register = ((endpoint) {
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
        }
      });

  /// Registers the contracts on a new connection's endpoint.
  final void Function(RpcResponderEndpoint endpoint) register;
}

/// Each connection gets an [RpcPeerEndpoint]; both sides may start calls.
final class RpcPeerMode extends RpcServerMode {
  /// [register] registers the contracts on each connection's endpoint.
  const RpcPeerMode(this.register);

  /// Registers the contracts on a new connection's endpoint.
  final void Function(RpcPeerEndpoint endpoint) register;
}

/// The per-connection half of a server: the endpoint for each connection, its
/// release when the connection ends, the connection cap, and drain-then-close.
///
/// The server keeps what is its own: accepting, the handshake, and how a
/// refused connection is told.
final class RpcConnectionHost {
  /// [maxConnections] caps the connections [admit] lets in, or null for no
  /// cap. [logController] is handed to every endpoint.
  RpcConnectionHost({
    required this.mode,
    this.maxConnections,
    LogScope? logger,
    LogController? logController,
  }) : _log = logger ?? LogScope.noop,
       _logController = logController;

  /// What each connection gets.
  final RpcServerMode mode;

  /// The cap on concurrent connections, or null.
  final int? maxConnections;

  final LogScope _log;
  final LogController? _logController;

  /// Every live endpoint, with what to run when it is released.
  final Map<RpcResponderEndpoint, void Function()?> _live = {};
  bool _warnedAtCap = false;

  /// Live connections.
  int get length => _live.length;

  /// Every live endpoint, peer-mode ones included. What `IRpcServer.endpoints`
  /// returns.
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_live.keys);

  /// Whether one more connection fits under the cap, counting [pending]
  /// connections the server holds that have no endpoint yet (a handshake in
  /// progress).
  ///
  /// A refusal is logged once per stretch at the cap: a client retrying in a
  /// loop would otherwise log every attempt.
  bool admit({int pending = 0}) {
    final cap = maxConnections;
    if (cap == null || _live.length + pending < cap) {
      _warnedAtCap = false;
      return true;
    }
    if (!_warnedAtCap) {
      _warnedAtCap = true;
      _log.warning('Refusing connections: at the connection limit ($cap)');
    }
    return false;
  }

  /// Builds and starts the endpoint for [transport], released when [done]
  /// completes, with a value or an error.
  ///
  /// [onRelease] runs once, when the endpoint is released. If the mode's
  /// register throws, the endpoint is released at once and the error
  /// rethrown; the server closes its connection.
  RpcResponderEndpoint serve(
    IRpcTransport transport, {
    required Future<void> done,
    String? debugLabel,
    void Function()? onRelease,
  }) {
    final RpcResponderEndpoint endpoint;
    switch (mode) {
      case RpcResponderMode(:final register):
        final responder = RpcResponderEndpoint(
          transport: transport,
          debugLabel: debugLabel,
          logController: _logController,
        );
        endpoint = responder;
        _live[endpoint] = onRelease;
        try {
          register(responder);
        } catch (_) {
          release(endpoint);
          rethrow;
        }
      case RpcPeerMode(:final register):
        final peer = RpcPeerEndpoint(
          transport: transport,
          debugLabel: debugLabel,
          logController: _logController,
        );
        endpoint = peer;
        _live[endpoint] = onRelease;
        try {
          register(peer);
        } catch (_) {
          release(endpoint);
          rethrow;
        }
    }
    endpoint.start();
    unawaited(
      done.then(
        (_) => release(endpoint),
        onError: (Object _) => release(endpoint),
      ),
    );
    return endpoint;
  }

  /// Drops [endpoint] and closes it, which is what disposes its contracts,
  /// then runs its `onRelease`. Idempotent.
  void release(RpcEndpointBase endpoint) {
    if (!_live.containsKey(endpoint)) return;
    final onRelease = _live.remove(endpoint);
    unawaited(
      endpoint.close().catchError((Object e) {
        _log.warning('Error closing an endpoint on disconnect: $e');
      }),
    );
    if (onRelease != null) {
      notifyWithoutDying('onConnectionClosed', onRelease, logger: _log);
    }
  }

  /// Closes every endpoint, optionally letting in-flight calls finish first.
  ///
  /// With [drainTimeout] null every endpoint closes at once and a running call
  /// fails with UNAVAILABLE. With a budget the endpoints stop admitting new
  /// calls, and their running ones get up to the budget to finish.
  Future<void> stop({Duration? drainTimeout}) async {
    if (drainTimeout != null) {
      for (final endpoint in _live.keys) {
        // markDraining, not drain(): the latter cancels every active context,
        // the opposite of letting in-flight calls finish.
        endpoint.markDraining();
      }
      await drainUntilIdle(
        pending: () => inFlightResponderCalls(_live.keys),
        budget: drainTimeout,
        logger: _log,
      );
    }
    // Concurrently: each close may wait on its own peer, and one dead
    // connection must not delay the rest. Caught per endpoint, because
    // Future.wait abandons the remaining futures on the first error.
    await Future.wait([
      for (final endpoint in List.of(_live.keys))
        endpoint.close().catchError((Object e) {
          _log.warning('Error closing an endpoint: $e');
        }),
    ]);
    for (final endpoint in List.of(_live.keys)) {
      release(endpoint);
    }
  }
}
