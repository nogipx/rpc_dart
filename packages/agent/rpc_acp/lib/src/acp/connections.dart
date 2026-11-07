// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'wire.dart';

/// A pair of connected ACP endpoints for embedding a client and agent.
final class AcpMemoryConnections {
  AcpMemoryConnections._(this.client, this.agent);

  factory AcpMemoryConnections.create({
    void Function(String side, Map<String, dynamic> message)? onMessage,
  }) {
    final client = AcpMemoryConnection._('client', onMessage);
    final agent = AcpMemoryConnection._('agent', onMessage);
    client._peer = agent;
    agent._peer = client;
    return AcpMemoryConnections._(client, agent);
  }

  final AcpMemoryConnection client;
  final AcpMemoryConnection agent;
}

/// One endpoint of an [AcpMemoryConnections] pair.
final class AcpMemoryConnection implements IAcpConnection {
  AcpMemoryConnection._(this._side, this._onMessage);

  final String _side;
  final void Function(String side, Map<String, dynamic> message)? _onMessage;
  final _incoming = StreamController<Map<String, dynamic>>();
  late final AcpMemoryConnection _peer;

  @override
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  @override
  void send(Map<String, dynamic> message) {
    if (_incoming.isClosed || _peer._incoming.isClosed) {
      throw StateError('ACP memory connection is closed');
    }
    _onMessage?.call(_side, message);
    _peer._incoming.add(message);
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// ACP JSON-RPC over UTF-8 newline-delimited streams.
///
/// The caller owns the input and output streams. [close] cancels the input
/// subscription and closes this connection's decoded-message stream.
final class AcpJsonLineConnection implements IAcpConnection {
  AcpJsonLineConnection(
    Stream<List<int>> input,
    void Function(String line) writeLine,
  ) : _writeLine = writeLine {
    _subscription = utf8.decoder
        .bind(input)
        .transform(const LineSplitter())
        .listen(
          _receive,
          onError: _messages.addError,
          onDone: () {
            if (!_messages.isClosed) _messages.close();
          },
        );
  }

  final void Function(String line) _writeLine;
  final _messages = StreamController<Map<String, dynamic>>();
  late final StreamSubscription<String> _subscription;
  final _batchIds = <Object?>{};
  final _batchReplies = <Map<String, dynamic>>[];
  int _batchExpected = 0;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  void _write(Object message) => _writeLine(jsonEncode(message));

  Map<String, dynamic> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  void _receive(String line) {
    Object? value;
    try {
      value = jsonDecode(line);
    } on FormatException {
      _write(_error(null, -32700, 'Parse error'));
      return;
    }
    if (value is List) {
      if (value.isEmpty) {
        _write(_error(null, -32600, 'Invalid Request'));
        return;
      }
      _batchIds.clear();
      _batchReplies.clear();
      _batchExpected = 0;
      for (final item in value) {
        if (item is! Map ||
            item['jsonrpc'] != '2.0' ||
            item['method'] is! String) {
          _batchReplies.add(_error(null, -32600, 'Invalid Request'));
          _batchExpected++;
          continue;
        }
        if (item.containsKey('id')) {
          _batchIds.add(item['id']);
          _batchExpected++;
        }
        _messages.add(item.cast<String, dynamic>());
      }
      _flushBatch();
    } else if (value is Map) {
      _messages.add(value.cast<String, dynamic>());
    } else {
      _write(_error(null, -32600, 'Invalid Request'));
    }
  }

  void _flushBatch() {
    if (_batchExpected == 0 || _batchReplies.length != _batchExpected) return;
    _write(_batchReplies);
    _batchIds.clear();
    _batchReplies.clear();
    _batchExpected = 0;
  }

  @override
  void send(Map<String, dynamic> message) {
    if (_batchIds.remove(message['id'])) {
      _batchReplies.add(message);
      _flushBatch();
    } else {
      _write(message);
    }
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    if (!_messages.isClosed) await _messages.close();
  }
}
