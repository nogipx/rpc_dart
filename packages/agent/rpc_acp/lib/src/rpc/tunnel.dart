// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../acp/wire.dart';
import 'contract.dart';

/// An [IAcpConnection] whose decoded JSON-RPC messages cross an rpc_dart peer.
/// The endpoint is owned by the caller and may use any rpc_dart transport.
final class RpcAcpConnection implements IAcpConnection {
  RpcAcpConnection(RpcPeerEndpoint endpoint) {
    final caller = AcpTunnelPeerCaller(endpoint);
    _subscription = caller
        .exchange(_outgoing.stream)
        .listen(
          (message) => _incoming.add(message.value),
          onError: (Object error, StackTrace stackTrace) {
            _closed = true;
            _incoming.addError(error, stackTrace);
          },
          onDone: () {
            _closed = true;
            unawaited(_incoming.close());
          },
        );
  }

  final _outgoing = StreamController<AcpRpcMessage>();
  final _incoming = StreamController<Map<String, dynamic>>();
  late final StreamSubscription<AcpRpcMessage> _subscription;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  @override
  void send(Map<String, dynamic> message) {
    if (_closed || _outgoing.isClosed) {
      throw StateError('ACP RPC connection is closed');
    }
    _outgoing.add(AcpRpcMessage(message));
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (!_outgoing.isClosed) await _outgoing.close();
    await _subscription.cancel();
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Receives one RPC message stream and relays it to an agent connection.
/// Register this contract before starting the peer endpoint. The receiver
/// owns and closes the agent connection when the tunnel ends.
final class AcpTunnelReceiver extends AcpTunnelPeer {
  AcpTunnelReceiver(super.endpoint, this._connection);

  final IAcpConnection _connection;

  @override
  Stream<AcpRpcMessage> onExchange(
    Stream<AcpRpcMessage> requests, {
    RpcContext? context,
  }) async* {
    final incoming = requests.listen(
      (message) => _connection.send(message.value),
      onError: (Object _, StackTrace stackTrace) =>
          unawaited(_connection.close()),
      onDone: () => unawaited(_connection.close()),
    );
    try {
      await for (final message in _connection.messages) {
        yield AcpRpcMessage(message);
      }
    } finally {
      await incoming.cancel();
      await _connection.close();
    }
  }
}
