// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';

class _InMemoryTransportPair {
  _InMemoryTransportPair()
      : _callerIncoming = StreamController<RpcTransportMessage>.broadcast(),
        _responderIncoming = StreamController<RpcTransportMessage>.broadcast() {
    caller = _InMemoryTransport(
      name: 'caller',
      isClient: true,
      incomingController: _callerIncoming,
      send: (message) {
        if (!_responderIncoming.isClosed) {
          _responderIncoming.add(message);
        }
      },
    );

    responder = _InMemoryTransport(
      name: 'responder',
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
  final Set<int> _activeStreams = <int>{};

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
    _activeStreams.add(id);
    return id;
  }

  @override
  bool releaseStreamId(int streamId) {
    return _activeStreams.remove(streamId);
  }

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
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    _ensureOpen();
    _send(
      RpcTransportMessage(
        directPayload: object,
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
        component: 'in-memory-$name',
        details: const {'reason': 'closed'},
      );
    }

    return RpcHealthStatus.healthy(
      component: 'in-memory-$name',
      details: {'activeStreams': _activeStreams.length},
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: 'in-memory-$name',
      message: 'Reconnect not supported in test transport',
      details: const {'supported': false},
    );
  }
}

class _SecureTestContext {
  _SecureTestContext({
    required this.pair,
    required this.callerKeys,
    required this.responderKeys,
    required this.caller,
    required this.responder,
  });

  final _InMemoryTransportPair pair;
  final LicensifyKeyPair callerKeys;
  final LicensifyKeyPair responderKeys;
  final SecureTransportAdapter caller;
  final SecureTransportAdapter responder;

  static Future<_SecureTestContext> create() async {
    final pair = _InMemoryTransportPair();
    final callerKeys = await Licensify.generateSigningKeys();
    final responderKeys = await Licensify.generateSigningKeys();

    final caller = SecureTransportAdapter.wrap(
      pair.caller,
      keyStore: SecureTransportKeyStore(
        transportId: 'caller-test',
        privateKey: callerKeys.privateKey,
        peerPublicKey: responderKeys.publicKey,
      ),
      logger: RpcLogger('secure-caller-test'),
    );

    final responder = SecureTransportAdapter.wrap(
      pair.responder,
      keyStore: SecureTransportKeyStore(
        transportId: 'responder-test',
        privateKey: responderKeys.privateKey,
        peerPublicKey: callerKeys.publicKey,
      ),
      logger: RpcLogger('secure-responder-test'),
    );

    await Future.wait([caller.ready, responder.ready]);

    return _SecureTestContext(
      pair: pair,
      callerKeys: callerKeys,
      responderKeys: responderKeys,
      caller: caller,
      responder: responder,
    );
  }

  Future<void> dispose() async {
    await caller.close();
    await responder.close();
    await pair.dispose();
    callerKeys.privateKey.dispose();
    callerKeys.publicKey.dispose();
    responderKeys.privateKey.dispose();
    responderKeys.publicKey.dispose();
  }
}

void main() {
  group('SecureTransportAdapter', () {
    late _SecureTestContext context;

    setUp(() async {
      context = await _SecureTestContext.create();
    });

    tearDown(() async {
      await context.dispose();
    });

    test('encrypts caller metadata and messages for responder', () async {
      final streamId = context.caller.createStream();
      final metadata = RpcMetadata([
        const RpcHeader(':method', 'POST'),
        const RpcHeader(':path', '/example.Service/DoWork'),
        const RpcHeader('x-custom', '123'),
      ]);

      final metadataFuture = context.responder.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.metadata != null)
          .first;

      await context.caller.sendMetadata(streamId, metadata);
      final receivedMetadata = await metadataFuture;

      expect(receivedMetadata.metadata, isNotNull);
      final receivedHeaders = receivedMetadata.metadata!.headers;
      expect(receivedHeaders.length, metadata.headers.length);
      for (var i = 0; i < metadata.headers.length; i++) {
        expect(receivedHeaders[i].name, metadata.headers[i].name);
        expect(receivedHeaders[i].value, metadata.headers[i].value);
      }

      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final dataFuture = context.responder.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.payload != null)
          .first;

      await context.caller.sendMessage(streamId, payload);
      final receivedData = await dataFuture;
      expect(receivedData.payload, isNotNull);
      expect(receivedData.payload, orderedEquals(payload));

      await context.caller.finishSending(streamId);
      final endFuture = context.responder.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.isEndOfStream)
          .first;
      final endMessage = await endFuture;
      expect(endMessage.isEndOfStream, isTrue);
    });

    test('encrypts responder replies back to caller', () async {
      final streamId = context.caller.createStream();

      final serverMetadata = RpcMetadata([
        const RpcHeader(':status', '200'),
        const RpcHeader('grpc-status', '0'),
      ]);

      final metadataFuture = context.caller.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.metadata != null)
          .first;

      await context.responder.sendMetadata(streamId, serverMetadata);
      final receivedMetadata = await metadataFuture;

      expect(receivedMetadata.metadata, isNotNull);
      expect(
        receivedMetadata.metadata!.headers.map((h) => (h.name, h.value)).toList(),
        containsAll([(':status', '200'), ('grpc-status', '0')]),
      );

      final responsePayload = Uint8List.fromList([9, 8, 7]);
      final dataFuture = context.caller.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.payload != null)
          .first;

      await context.responder.sendMessage(streamId, responsePayload);
      final receivedData = await dataFuture;
      expect(receivedData.payload, orderedEquals(responsePayload));
    });
  });
}
