// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The ACP wire: JSON-RPC 2.0 over a line-based connection, with a
/// per-session fan-out for `session/update` notifications.
///
/// The client interprets ACP; the connection only carries decoded messages.
library;

import 'dart:async';

import 'json_rpc.dart';

/// A decoded-message transport. Implementations own the byte framing
/// (NDJSON over stdio today; a socket later).
abstract interface class IAcpConnection {
  /// Decoded JSON-RPC messages from the agent.
  Stream<Map<String, dynamic>> get messages;

  /// Sends one JSON-RPC message to the agent.
  void send(Map<String, dynamic> message);

  Future<void> close();
}

/// Handles a request the AGENT sent to us (the permission flow). Assigned
/// by the client after it constructs the wire.
typedef AgentRequestHandler =
    Future<Object?> Function(String method, Map<String, dynamic> params);

/// JSON-RPC engine for one ACP agent connection.
final class JsonRpcWire {
  JsonRpcWire(this.connection) {
    _peer = JsonRpcPeer(
      send: _send,
      onRequest: (method, params) async {
        final handler = onAgentRequest;
        if (handler == null) {
          throw JsonRpcException(
            -32601,
            'No agent-request handler installed yet: $method',
          );
        }
        return handler(method, params);
      },
      onNotification: _handleNotification,
    );
    _subscription = connection.messages.listen(
      _peer.message,
      onError: _fail,
      onDone: () => _fail(StateError('ACP agent closed its stdout')),
    );
  }

  final IAcpConnection connection;
  AgentRequestHandler? onAgentRequest;

  /// Handler for agent-originated notifications other than
  /// `session/update` (today: `elicitation/complete`). Optional; null
  /// means the notification is dropped, same as ACP's fire-and-forget.
  void Function(String method, Map<String, dynamic> params)?
  onAgentNotification;

  late final JsonRpcPeer _peer;
  late final StreamSubscription<void> _subscription;

  /// Every `session/update` body with its session id, including updates
  /// outside prompt windows.
  final _allUpdates =
      StreamController<(String, Map<String, dynamic>)>.broadcast();

  final _sessions = <String, StreamController<Map<String, dynamic>>>{};

  /// Sends a request and completes with the decoded `result`.
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final result = await _peer.request(method, params);
    return result as Map<String, dynamic>;
  }

  /// Sends a notification (no response expected).
  void notify(String method, [Map<String, dynamic>? params]) {
    _peer.notify(method, params);
  }

  /// The update stream of one session. Ends after [endSession] — which
  /// [AcpWireCaller] calls when the matching `session/prompt` response
  /// arrives, ACP being a request/response protocol where the turn's end is
  /// the response, not anything in the notification stream.
  Stream<Map<String, dynamic>> sessionUpdates(String sessionId) {
    final controller = _sessions.putIfAbsent(
      sessionId,
      () => StreamController<Map<String, dynamic>>.broadcast(),
    );
    return controller.stream;
  }

  /// Every `session/update` the agent sends, with its session id. The remote
  /// layer records this feed into per-session event logs; nothing above it
  /// needs to know the updates exist twice.
  Stream<(String, Map<String, dynamic>)> get allUpdates => _allUpdates.stream;

  /// Closes the per-session update stream. Events already added are
  /// delivered before `done`; a close only stops what comes after.
  void endSession(String sessionId) {
    _sessions.remove(sessionId)?.close();
  }

  Future<void> dispose() async {
    _fail(StateError('ACP wire disposed'));
    await _subscription.cancel();
    for (final controller in _sessions.values) {
      await controller.close();
    }
    await _allUpdates.close();
    // The process outlives its subscription: cancel what listens, then close
    // what feeds it, or the agent child process keeps the VM alive after
    // everything else is done.
    await connection.close();
  }

  void _send(Map<String, dynamic> message) {
    connection.send(message);
  }

  void _handleNotification(String method, Map<String, dynamic> params) {
    if (method == 'session/update') {
      final sessionId = params['sessionId'] as String?;
      final update = params['update'];
      if (sessionId == null || update is! Map) return;
      final body = update.cast<String, dynamic>();
      _allUpdates.add((sessionId, body));
      _sessions[sessionId]?.add(body);
      return;
    }
    // Other agent-originated notifications (today: elicitation/complete)
    // route to the app through the same reverse channel as requests.
    if (method == 'elicitation/complete') {
      onAgentNotification?.call(method, params);
    }
  }

  void _fail(Object error) {
    _peer.failAll(error);
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final controller in sessions) {
      if (!controller.isClosed) {
        controller.addError(error);
        unawaited(controller.close());
      }
    }
  }
}
