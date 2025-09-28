// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

Future<void> main() async {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  final callerKeys = await Licensify.generateSigningKeys();
  final responderKeys = await Licensify.generateSigningKeys();
  final transportPair = _InMemoryTransportPair();

  final caller = SecureTransportAdapter.wrap(
    transportPair.caller,
    keyStore: SecureTransportKeyStore(
      transportId: 'demo-caller',
      privateKey: callerKeys.privateKey,
      peerPublicKey: responderKeys.publicKey,
    ),
    logger: RpcLogger('SecureDemoCaller'),
  );

  final responder = SecureTransportAdapter.wrap(
    transportPair.responder,
    keyStore: SecureTransportKeyStore(
      transportId: 'demo-responder',
      privateKey: responderKeys.privateKey,
      peerPublicKey: callerKeys.publicKey,
    ),
    logger: RpcLogger('SecureDemoResponder'),
  );

  await Future.wait([caller.ready, responder.ready]);
  print('🔐 Secure channel established between caller and responder');

  final responderSubscription = responder.incomingMessages.listen((message) {
    if (message.metadata != null) {
      print('➡️  Responder received metadata: ${message.metadata!.headers}');
      unawaited(responder.sendMetadata(
        message.streamId,
        RpcMetadata.forServerInitialResponse(),
      ));
      return;
    }

    if (message.payload != null) {
      final text = utf8.decode(message.payload!);
      print('➡️  Responder received payload: $text');
      final reply = utf8.encode('Reply for "$text"');
      unawaited(responder.sendMessage(
        message.streamId,
        Uint8List.fromList(reply),
      ));
      unawaited(responder.finishSending(message.streamId));
    }
  });

  final callerSubscription = caller.incomingMessages.listen((message) {
    if (message.metadata != null) {
      print('⬅️  Caller received metadata: ${message.metadata!.headers}');
      return;
    }

    if (message.payload != null) {
      final text = utf8.decode(message.payload!);
      print('⬅️  Caller received encrypted reply: $text');
    }

    if (message.isEndOfStream) {
      print('⬅️  Caller stream ${message.streamId} completed');
    }
  });

  final streamId = caller.createStream();
  await caller.sendMetadata(
    streamId,
    RpcMetadata.forClientRequestWithPath('/demo.SecureService/SayHello'),
  );

  await caller.sendMessage(
    streamId,
    Uint8List.fromList(utf8.encode('Hello secure world!')),
  );

  await caller.finishSending(streamId);

  await Future.delayed(const Duration(milliseconds: 300));

  await responderSubscription.cancel();
  await callerSubscription.cancel();
  await caller.close();
  await responder.close();
  await transportPair.dispose();
  callerKeys.privateKey.dispose();
  callerKeys.publicKey.dispose();
  responderKeys.privateKey.dispose();
  responderKeys.publicKey.dispose();

  print('✅ Demo finished, secure transport adapter cleaned up');
}

class _InMemoryTransportPair {
  _InMemoryTransportPair()
      : _callerIncoming = StreamController<RpcTransportMessage>.broadcast(),
        _responderIncoming = StreamController<RpcTransportMessage>.broadcast() {
    caller = _InMemoryTransport(
      name: 'demo-caller',
      isClient: true,
      incomingController: _callerIncoming,
      send: (message) {
        if (!_responderIncoming.isClosed) {
          _responderIncoming.add(message);
        }
      },
    );

    responder = _InMemoryTransport(
      name: 'demo-responder',
      isClient: false,
      incomingController: _responderIncoming,
      send: (message) {
        if (!_callerIncoming.isClosed) {
          _callerIncoming.add(message);
        }
      },
    );
  }

  late final _InMemoryTransport caller;
  late final _InMemoryTransport responder;

  final StreamController<RpcTransportMessage> _callerIncoming;
  final StreamController<RpcTransportMessage> _responderIncoming;

  Future<void> dispose() async {
    await Future.wait([
      if (!_callerIncoming.isClosed) _callerIncoming.close(),
      if (!_responderIncoming.isClosed) _responderIncoming.close(),
    ]);
  }
}

class _InMemoryTransport implements IRpcTransport {
  _InMemoryTransport({
    required this.name,
    required this.isClient,
    required StreamController<RpcTransportMessage> incomingController,
    required void Function(RpcTransportMessage message) send,
  })  : _incomingController = incomingController,
        _send = send,
        _nextStreamId = isClient ? 1 : 2;

  final String name;
  @override
  final bool isClient;
  final StreamController<RpcTransportMessage> _incomingController;
  final void Function(RpcTransportMessage message) _send;

  bool _closed = false;
  int _nextStreamId;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Transport $name is closed');
    }
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  int createStream() {
    _ensureOpen();
    final id = _nextStreamId;
    _nextStreamId += 2;
    return id;
  }

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    _ensureOpen();
    _send(
      RpcTransportMessage(
        metadata: metadata,
        streamId: streamId,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
      ),
    );
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    _ensureOpen();
    _send(
      RpcTransportMessage.withPayload(
        payload: Uint8List.fromList(data),
        streamId: streamId,
        isEndOfStream: endStream,
      ),
    );
  }

  @override
  Future<void> finishSending(int streamId) async {
    _ensureOpen();
    _send(
      RpcTransportMessage(
        streamId: streamId,
        isEndOfStream: true,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _incomingController.close();
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: 'demo-transport-$name',
      );
    }

    return RpcHealthStatus.healthy(
      component: 'demo-transport-$name',
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: 'demo-transport-$name',
      message: 'Reconnect not implemented for demo transport',
      details: const {'supported': false},
    );
  }
}
