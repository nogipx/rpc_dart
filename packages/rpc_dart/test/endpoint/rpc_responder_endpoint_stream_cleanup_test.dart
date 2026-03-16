// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _TestService extends RpcResponderContract {
  static const name = 'TestService';

  _TestService() : super(name);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'EchoUnary',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async => request,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'EchoServerStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async* {
        yield RpcString('${request.value}:1');
        yield RpcString('${request.value}:2');
      },
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'EchoClientStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (requests, {context}) async {
        final values = await requests.map((e) => e.value).toList();
        return RpcString(values.join(','));
      },
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'EchoBidi',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (requests, {context}) {
        return requests.map((e) => RpcString('echo:${e.value}'));
      },
    );
  }
}

Future<int> _openStreams(RpcResponderEndpoint endpoint) async {
  final health = await endpoint.health();
  return (health.endpointStatus.details['openStreams'] as int?) ?? -1;
}

void main() {
  group('RpcResponderEndpoint stream cleanup', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcCallerEndpoint callerEndpoint;
    late RpcResponderEndpoint responderEndpoint;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
      responderEndpoint = RpcResponderEndpoint(transport: serverTransport)
        ..registerServiceContract(_TestService())
        ..start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
    });

    test('cleans up after unary call completes', () async {
      final res = await callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: _TestService.name,
        methodName: 'EchoUnary',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: const RpcString('ok'),
      );
      expect(res.value, equals('ok'));

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await _openStreams(responderEndpoint), equals(0));
    });

    test('cleans up after server stream completes', () async {
      final items = await callerEndpoint
          .serverStream<RpcString, RpcString>(
            serviceName: _TestService.name,
            methodName: 'EchoServerStream',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: const RpcString('ok'),
          )
          .map((e) => e.value)
          .toList();

      expect(items, equals(['ok:1', 'ok:2']));

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await _openStreams(responderEndpoint), equals(0));
    });

    test('cleans up after client stream completes', () async {
      final call = callerEndpoint.clientStream<RpcString, RpcString>(
        serviceName: _TestService.name,
        methodName: 'EchoClientStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      );

      final res = await call(
        Stream.fromIterable(const [
          RpcString('a'),
          RpcString('b'),
        ]),
      );
      expect(res.value, equals('a,b'));

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await _openStreams(responderEndpoint), equals(0));
    });

    test('cleans up after bidirectional stream completes', () async {
      final controller = StreamController<RpcString>();
      final responses = callerEndpoint
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: _TestService.name,
            methodName: 'EchoBidi',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            requests: controller.stream,
          )
          .map((e) => e.value)
          .toList();

      controller
        ..add(const RpcString('a'))
        ..add(const RpcString('b'));
      await controller.close();

      expect(await responses, equals(['echo:a', 'echo:b']));

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await _openStreams(responderEndpoint), equals(0));
    });

    test(
        'returns invalidArgument and cleans up when request ends without payload',
        () async {
      final streamId = clientTransport.createStream();

      final response = clientTransport.incomingMessages.firstWhere(
        (message) =>
            message.streamId == streamId &&
            message.isMetadataOnly &&
            message.metadata?.getHeaderValue(RpcHeaders.grpcStatus) !=
                null,
      );

      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest(_TestService.name, 'EchoUnary'),
        endStream: true,
      );

      final trailer = await response;
      expect(
        trailer.metadata!.getHeaderValue(RpcHeaders.grpcStatus),
        equals(RpcStatus.invalidArgument.toString()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await _openStreams(responderEndpoint), equals(0));
    });

    test('returns unimplemented and cleans up for unknown method', () async {
      final streamId = clientTransport.createStream();

      final response = clientTransport.incomingMessages.firstWhere(
        (message) =>
            message.streamId == streamId &&
            message.isMetadataOnly &&
            message.metadata?.getHeaderValue(RpcHeaders.grpcStatus) !=
                null,
      );

      await clientTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest(_TestService.name, 'MissingMethod'),
        endStream: true,
      );

      final trailer = await response;
      expect(
        trailer.metadata!.getHeaderValue(RpcHeaders.grpcStatus),
        equals(RpcStatus.unimplemented.toString()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(await _openStreams(responderEndpoint), equals(0));
    });
  });
}
