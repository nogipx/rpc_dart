// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Middleware defaults', () {
    test('default middleware/interceptor are pass-through', () async {
      final endpoint = RpcCallerEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      endpoint
        ..addMiddleware(const _NoopMiddleware())
        ..addInterceptor(const _NoopInterceptor());

      final context = RpcContext.withHeaders({'k': 'v'});

      final result = await endpoint.handleUnary<int, int>(
        serviceName: 'svc',
        methodName: 'method',
        context: context,
        request: 10,
        handler: (ctx, request) async {
          expect(ctx.getHeader('k'), equals('v'));
          return request + 1;
        },
      );

      expect(result, equals(11));
    });

    test('RpcMiddlewareContext.copyWith and updateContext preserve fields', () {
      final endpoint = RpcCallerEndpoint(transport: _DummyTransport());

      final call = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'svc',
        methodName: 'method',
        context: RpcContext.withHeaders({'a': '1'}),
      );

      call.updateContext(call.context.withAdditionalHeaders({'b': '2'}));

      expect(call.context.getHeader('a'), equals('1'));
      expect(call.context.getHeader('b'), equals('2'));

      final copy = call.copyWith(methodName: 'other');
      expect(copy.serviceName, equals('svc'));
      expect(copy.methodName, equals('other'));
      expect(copy.endpoint, same(endpoint));
      expect(copy.context.getHeader('b'), equals('2'));
    });
  });
}

final class _NoopMiddleware extends IRpcMiddleware {
  const _NoopMiddleware();
}

final class _NoopInterceptor extends IRpcInterceptor {
  const _NoopInterceptor();
}

final class _DummyTransport extends IRpcTransport {
  bool _closed = false;

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  int createStream() => 1;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) {
    throw UnsupportedError('sendMetadata is not used in tests');
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) {
    throw UnsupportedError('sendMessage is not used in tests');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      const Stream<RpcTransportMessage>.empty();

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'DummyTransport');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'DummyTransport');
}

