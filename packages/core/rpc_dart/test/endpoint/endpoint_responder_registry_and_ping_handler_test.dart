// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

void main() {
  group('RpcResponderMethodRegistry', () {
    test('exports zero-copy methods with wrapped handlers', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(() async {
        await responder.close();
        await client.close();
      });

      responder.registerServiceContract(_ZeroCopyContract());

      final methods = responder.registeredMethods;

      final unary = methods['ZeroCopy.Unary']!;
      final serverStream = methods['ZeroCopy.ServerStream']!;
      final clientStream = methods['ZeroCopy.ClientStream']!;
      final bidi = methods['ZeroCopy.Bidi']!;

      final unaryResult = await (unary.handler as dynamic)(
        'ping',
        context: RpcContext.empty(),
      );
      expect(unaryResult, equals('pong: ping'));

      final serverStreamResult = await (serverStream.handler as dynamic)(
        1,
        context: RpcContext.empty(),
      );
      expect(await (serverStreamResult as Stream).toList(), equals([1, 2]));

      final clientStreamResult = await (clientStream.handler as dynamic)(
        Stream<int>.fromIterable([1, 2, 3]),
        context: RpcContext.empty(),
      );
      expect(clientStreamResult, equals(6));

      final bidiResult = await (bidi.handler as dynamic)(
        Stream<String>.fromIterable(['a', 'b']),
        context: RpcContext.empty(),
      );
      expect(await (bidiResult as Stream).toList(), equals(['A', 'B']));

      expect(
        () => unary.requestCodec.serialize(_DummySerializable()),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => unary.requestCodec.deserialize(Uint8List(0)),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('unregister ignores contract dispose errors', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      final responder = RpcResponderEndpoint(transport: server);
      addTearDown(() async {
        await responder.close();
        await client.close();
      });

      responder.registerServiceContract(_DisposeThrowsContract());
      expect(responder.registeredContracts, contains('DisposeThrows'));

      responder.unregisterServiceContract('DisposeThrows');
      expect(responder.registeredContracts, isNot(contains('DisposeThrows')));
    });
  });

  group('RpcResponderPingHandler', () {
    test('responds with timestamps and debug label', () async {
      final (client, server) = RpcInMemoryTransport.pair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final streamId = client.createStream();
      final handler = RpcResponderPingHandler(
        transport: server,
        logger: LogScope.noop,
        debugLabel: 'srv',
      );

      final metadata = <RpcMetadata>[];
      final sub = client.getMessagesForStream(streamId).listen((message) {
        if (message.isMetadataOnly && message.metadata != null) {
          metadata.add(message.metadata!);
        }
      });
      addTearDown(() => sub.cancel());

      await handler.respond(
        streamId: streamId,
        context: RpcContext.withHeaders({'x': 'y'}),
        onComplete: () async {},
      );

      final trailer = metadata
          .map((m) => m.getHeaderValue(RpcHeaders.grpcStatus))
          .whereType<String>()
          .toList();
      expect(trailer, equals([RpcStatus.ok.toString()]));

      final debugLabel = metadata
          .expand((m) => m.headers)
          .where(
              (h) => h.name == RpcEndpointPingProtocol.responseDebugLabelHeader)
          .map((h) => h.value)
          .toList();
      expect(debugLabel, equals(['srv']));
    });

    test('on transport error sends INTERNAL trailers when possible', () async {
      final (client, serverInner) = RpcInMemoryTransport.pair();

      final server = _ThrowOnceOnSendMetadata(serverInner)
        ..errorToThrow = StateError('fail once');

      addTearDown(() async {
        await client.close();
        await serverInner.close();
      });

      final streamId = client.createStream();
      final handler = RpcResponderPingHandler(
        transport: server,
        logger: LogScope.noop,
        debugLabel: null,
      );

      final trailers = Completer<RpcMetadata>();
      final sub = client.getMessagesForStream(streamId).listen((message) {
        final metadata = message.metadata;
        if (metadata == null) return;
        final status = metadata.getHeaderValue(RpcHeaders.grpcStatus);
        if (status != null && !trailers.isCompleted) {
          trailers.complete(metadata);
        }
      });
      addTearDown(() => sub.cancel());

      await handler.respond(
        streamId: streamId,
        context: RpcContext.empty(),
        onComplete: () async {},
      );

      final trailer = await trailers.future.timeout(const Duration(seconds: 2));
      expect(
        trailer.getHeaderValue(RpcHeaders.grpcStatus),
        equals(RpcStatus.internal.toString()),
      );
      expect(
        RpcMetadata.decodeGrpcMessage(
          trailer.getHeaderValue(RpcHeaders.grpcMessage) ?? '',
        ),
        contains('Ping handling error'),
      );
    });

    test('still completes onComplete when transport fails', () async {
      final (client, serverInner) = RpcInMemoryTransport.pair();
      final server = ThrowingTransport(serverInner)
        ..throwOnSendMetadata = true
        ..errorToThrow = StateError('always fail');

      addTearDown(() async {
        await client.close();
        await serverInner.close();
      });

      final handler = RpcResponderPingHandler(
        transport: server,
        logger: LogScope.noop,
        debugLabel: null,
      );

      final completed = Completer<void>();
      await handler.respond(
        streamId: client.createStream(),
        context: RpcContext.empty(),
        onComplete: () async => completed.complete(),
      );

      await completed.future.timeout(const Duration(seconds: 2));
    });
  });
}

final class _ZeroCopyContract extends RpcResponderContract {
  _ZeroCopyContract()
      : super('ZeroCopy', dataTransferMode: RpcDataTransferMode.auto);

  @override
  void setup() {
    addUnaryMethod<String, String>(
      methodName: 'Unary',
      handler: (request, {context}) async => 'pong: $request',
    );

    addServerStreamMethod<int, int>(
      methodName: 'ServerStream',
      handler: (request, {context}) =>
          Stream<int>.fromIterable([request, request + 1]),
    );

    addClientStreamMethod<int, int>(
      methodName: 'ClientStream',
      handler: (requests, {context}) async {
        var sum = 0;
        await for (final value in requests) {
          sum += value;
        }
        return sum;
      },
    );

    addBidirectionalMethod<String, String>(
      methodName: 'Bidi',
      handler: (requests, {context}) =>
          requests.map((value) => value.toUpperCase()),
    );
  }
}

final class _DisposeThrowsContract extends RpcResponderContract {
  _DisposeThrowsContract() : super('DisposeThrows');

  @override
  void setup() {
    addUnaryMethod<String, String>(
      methodName: 'Unary',
      handler: (request, {context}) async => request,
    );
  }

  @override
  void dispose() {
    throw StateError('dispose failed');
  }
}

final class _DummySerializable implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => const {};
}

final class _ThrowOnceOnSendMetadata implements IRpcTransport {
  final IRpcTransport _inner;
  bool _thrown = false;
  Object errorToThrow = StateError('sendMetadata failed');

  _ThrowOnceOnSendMetadata(this._inner);

  @override
  bool get isClient => _inner.isClient;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  bool get supportsZeroCopy => _inner.supportsZeroCopy;

  @override
  int createStream() => _inner.createStream();

  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (!_thrown) {
      _thrown = true;
      throw errorToThrow;
    }
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) =>
      _inner.sendMessage(streamId, data, endStream: endStream);

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) =>
      _inner.sendDirectObject(streamId, object, endStream: endStream);

  @override
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);

  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<RpcHealthStatus> health() => _inner.health();

  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();
}
