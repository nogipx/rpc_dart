// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';

void main() {
  group('SecureTransportAdapter handshake protection', () {
    late LicensifyKeyPair callerKeys;
    late LicensifyKeyPair responderKeys;

    setUp(() async {
      callerKeys = await Licensify.generateSigningKeys();
      responderKeys = await Licensify.generateSigningKeys();
    });

    tearDown(() async {
      callerKeys.privateKey.dispose();
      callerKeys.publicKey.dispose();
      responderKeys.privateKey.dispose();
      responderKeys.publicKey.dispose();
    });

    test('completes handshake and forwards post-handshake payloads', () async {
      final pair = _LoopbackTransportPair();
      final callerLogger = _RecordingLogger('caller');
      final responderLogger = _RecordingLogger('responder');

      final caller = SecureTransportAdapter.wrap(
        pair.client,
        keyStore: SecureTransportKeyStore(
          transportId: 'caller',
          keyPair: callerKeys,
          peerPublicKey: responderKeys.publicKey,
        ),
        logger: callerLogger,
      );

      final responder = SecureTransportAdapter.wrap(
        pair.server,
        keyStore: SecureTransportKeyStore(
          transportId: 'responder',
          keyPair: responderKeys,
          peerPublicKey: callerKeys.publicKey,
        ),
        logger: responderLogger,
      );

      await Future.wait([caller.ready, responder.ready]);

      final streamId = caller.createStream();
      await caller.sendMetadata(streamId, const RpcMetadata([]));

      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final receivedFuture = responder.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.payload != null)
          .first;

      await caller.sendMessage(streamId, payload, endStream: true);
      final received = await receivedFuture.timeout(const Duration(seconds: 5));

      expect(received.payload, isNotNull);
      expect(received.payload, payload);

      await Future.wait([caller.close(), responder.close()]);
    });

    test('discovers peer keys dynamically during handshake', () async {
      final pair = _LoopbackTransportPair();

      final caller = SecureTransportAdapter.wrap(
        pair.client,
        keyStore: SecureTransportKeyStore(
          transportId: 'caller',
          keyPair: callerKeys,
        ),
      );

      final responder = SecureTransportAdapter.wrap(
        pair.server,
        keyStore: SecureTransportKeyStore(
          transportId: 'responder',
          keyPair: responderKeys,
        ),
      );

      await Future.wait([caller.ready, responder.ready]);

      final streamId = caller.createStream();
      final payload = Uint8List.fromList([9, 8, 7, 6]);
      final receivedFuture = responder.incomingMessages
          .where((message) =>
              message.streamId == streamId && message.payload != null)
          .first;

      await caller.sendMessage(streamId, payload, endStream: true);
      final received = await receivedFuture.timeout(const Duration(seconds: 5));

      expect(received.payload, payload);

      await Future.wait([caller.close(), responder.close()]);
    });

    test('drops excessive pre-handshake traffic and closes connection',
        () async {
      final pair = _LoopbackTransportPair();
      final logger = _RecordingLogger('responder');

      final responder = SecureTransportAdapter.wrap(
        pair.server,
        keyStore: SecureTransportKeyStore(
          transportId: 'responder',
          keyPair: responderKeys,
          peerPublicKey: callerKeys.publicKey,
        ),
        config: const SecureTransportConfig(
          handshakeTimeout: Duration(milliseconds: 200),
          pendingHandshakeMessageLimit: 1,
        ),
        logger: logger,
      );

      // Allow the listener wiring in SecureTransportAdapter to complete.
      await Future<void>.delayed(Duration.zero);

      // First message is buffered, second should trigger the protection logic.
      pair.server.injectIncoming(
        RpcTransportMessage.withPayload(
          payload: Uint8List.fromList([1]),
          streamId: 1,
        ),
      );
      pair.server.injectIncoming(
        RpcTransportMessage.withPayload(
          payload: Uint8List.fromList([2]),
          streamId: 1,
        ),
      );

      await expectLater(
        responder.ready,
        throwsA(isA<StateError>()),
      );

      await pumpEventQueue(times: 3);
      expect(responder.isClosed, isTrue);
      expect(logger.warningMessages, isNotEmpty);
      await responder.close();
      await pair.client.close();
    });
  });
}

Future<void> pumpEventQueue({int times = 1}) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _LoopbackTransportPair {
  _LoopbackTransportPair()
      : client = _LoopbackTransport(isClient: true),
        server = _LoopbackTransport(isClient: false) {
    client.peer = server;
    server.peer = client;
  }

  final _LoopbackTransport client;
  final _LoopbackTransport server;
}

class _LoopbackTransport implements IRpcTransport {
  _LoopbackTransport({required this.isClient})
      : _incoming = StreamController<RpcTransportMessage>.broadcast(),
        _nextStreamId = isClient ? -1 : 0;

  late _LoopbackTransport peer;
  final StreamController<RpcTransportMessage> _incoming;
  bool _closed = false;
  int _nextStreamId;

  @override
  final bool isClient;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => _nextStreamId += 2;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    final message = RpcTransportMessage(
      metadata: metadata,
      streamId: streamId,
      isEndOfStream: endStream,
    );
    _deliverToPeer(message);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    final message = RpcTransportMessage(
      payload: data,
      streamId: streamId,
      isEndOfStream: endStream,
    );
    _deliverToPeer(message);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) {
    throw UnsupportedError(
        'Direct objects not supported in loopback transport');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) {
      throw StateError('Transport closed');
    }
    _deliverToPeer(
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
    await _incoming.close();
  }

  @override
  Future<RpcHealthStatus> health() async => RpcHealthStatus.healthy(
        component: 'LoopbackTransport',
        message: 'Loopback healthy',
      );

  @override
  Future<RpcHealthStatus> reconnect() async => RpcHealthStatus.degraded(
        component: 'LoopbackTransport',
        message: 'Reconnect unsupported',
        details: const {'supported': false},
      );

  void injectIncoming(RpcTransportMessage message) {
    if (_closed) {
      throw StateError('Transport closed');
    }
    _incoming.add(message);
  }

  void _deliverToPeer(RpcTransportMessage message) {
    scheduleMicrotask(() {
      if (!peer._closed) {
        peer._incoming.add(message);
      }
    });
  }

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((e) => e.streamId == streamId);
  }
}

class _RecordingLogger implements RpcLogger {
  _RecordingLogger(this.name);

  final List<_LogEntry> _entries = [];

  @override
  final String name;

  List<String> get warningMessages => _entries
      .where((entry) => entry.level == RpcLoggerLevel.warning)
      .map((entry) => entry.message)
      .toList(growable: false);

  @override
  RpcLogger child(String childName, {String? label}) => this;

  @override
  Future<void> critical(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(RpcLoggerLevel.critical, message);

  @override
  Future<void> debug(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(RpcLoggerLevel.debug, message);

  @override
  Future<void> error(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(RpcLoggerLevel.error, message);

  @override
  Future<void> info(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(RpcLoggerLevel.info, message);

  @override
  Future<void> internal(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(RpcLoggerLevel.debug, message);

  @override
  Future<void> log({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(level, message);

  @override
  Future<void> warning(
    String message, {
    String? context,
    String? requestId,
    String? traceId,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) =>
      _record(RpcLoggerLevel.warning, message);

  Future<void> _record(RpcLoggerLevel level, String message) async {
    _entries.add(_LogEntry(level, message));
  }
}

class _LogEntry {
  _LogEntry(this.level, this.message);

  final RpcLoggerLevel level;
  final String message;
}
