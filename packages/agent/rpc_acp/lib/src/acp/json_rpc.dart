// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// JSON-RPC 2.0 framing shared by both ACP directions.
///
/// Deliberately wire-faithful and nothing more: the caller owns the byte
/// stream, this class owns request/response matching and the dispatch of
/// agent-originated requests. It makes no ACP assumptions.
library;

import 'dart:async';

/// Thrown for a JSON-RPC error response.
final class JsonRpcException implements Exception {
  const JsonRpcException(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'JSON-RPC error $code: $message';
}

/// Agent requires authentication before the failed method may be called.
const int kAuthRequired = -32000;

/// The agent supports none of the protocol versions the client requested.
/// Error data carries `requested` (int) and `supported` (list of int).
const int kUnsupportedProtocolVersion = -32022;

/// Handles a request the peer (the agent) sent to us. Must return the
/// JSON-encodable result, or throw [JsonRpcException] / any other error
/// (reported back as internal error).
typedef PeerRequestHandler =
    Future<Object?> Function(String method, Map<String, dynamic> params);

typedef PeerNotificationHandler =
    void Function(String method, Map<String, dynamic> params);

/// One JSON-RPC peer: sends through [send], consumes decoded messages
/// through [message].
final class JsonRpcPeer {
  JsonRpcPeer({
    required void Function(Map<String, dynamic> message) send,
    required PeerRequestHandler onRequest,
    PeerNotificationHandler? onNotification,
  }) : _send = send,
       _onRequest = onRequest,
       _onNotification = onNotification;

  final void Function(Map<String, dynamic>) _send;
  final PeerRequestHandler _onRequest;
  final PeerNotificationHandler? _onNotification;

  int _nextId = 0;
  bool _closed = false;
  final _pending = <int, Completer<Object?>>{};

  /// Dispatches one decoded JSON-RPC message.
  void message(Map<String, dynamic> message) {
    if (_closed) return;
    final Object? id = message['id'];
    if (message.containsKey('method')) {
      final method = message['method'] as String;
      final params =
          (message['params'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      if (id == null) {
        // ACP's $/cancel_request: the peer asks us to cancel an outgoing
        // request of ours. Failing the pending completer is the honest
        // answer; the caller sees the same Cancelled the peer was told.
        if (method == r'$/cancel_request') {
          final requestId = params['requestId'];
          if (requestId is int) {
            final pending = _pending.remove(requestId);
            pending?.completeError(
              const JsonRpcException(-32800, 'Request cancelled'),
            );
          }
          return;
        }
        _onNotification?.call(method, params);
      } else {
        // A request from the peer is always answered, even when the handler
        // throws — a silent drop reads to the peer as a hang, not an error.
        _onRequest(method, params).then(
          (result) => _reply(id, result, null),
          onError: (Object error) => _reply(
            id,
            null,
            error is JsonRpcException
                ? error
                : JsonRpcException(-32603, 'Internal error: $error'),
          ),
        );
      }
      return;
    }
    if (id is int) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      if (message.containsKey('error')) {
        final error = (message['error'] as Map).cast<String, dynamic>();
        pending.completeError(
          JsonRpcException(
            error['code'] as int,
            error['message'] as String? ?? 'error',
            error['data'],
          ),
        );
      } else {
        pending.complete(message['result']);
      }
    }
  }

  /// Sends a request and completes with the decoded `result`, or throws
  /// [JsonRpcException] on an error response.
  Future<Object?> request(String method, [Map<String, dynamic>? params]) {
    if (_closed) {
      return Future.error(StateError('JSON-RPC peer is closed'));
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    });
    return completer.future;
  }

  /// Sends a notification (no response expected).
  void notify(String method, [Map<String, dynamic>? params]) {
    if (_closed) return;
    _send(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  void _reply(Object id, Object? result, JsonRpcException? error) {
    if (_closed) return;
    if (error != null) {
      _send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, dynamic>{
          'code': error.code,
          'message': error.message,
          if (error.data != null) 'data': error.data,
        },
      });
    } else {
      _send(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});
    }
  }

  /// Fails every pending request and ignores everything afterwards.
  void failAll(Object error) {
    _closed = true;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(error);
    }
  }
}
