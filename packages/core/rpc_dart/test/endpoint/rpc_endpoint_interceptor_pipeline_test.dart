// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpointBase interceptor pipeline', () {
    test('handleUnary runs the interceptors outermost first', () async {
      final endpoint = RpcCallerEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      final events = <String>[];
      endpoint
        ..addInterceptor(_OuterUnaryInterceptor(events))
        ..addInterceptor(_InnerUnaryInterceptor(events));

      final result = await endpoint.handleUnary<int, int>(
        serviceName: 'svc',
        methodName: 'method',
        context: RpcContext.withHeaders({'initial': 'value'}),
        direction: RpcCallDirection.outgoing,
        request: 1,
        handler: (ctx, request) async {
          events.add('handler request $request headers ${ctx.headers}');
          expect(ctx.getHeader('A'), equals('yes'));
          expect(ctx.getHeader('B'), equals('true'));
          return request + 5;
        },
      );

      expect(result, equals(176));
      expect(
        events,
        equals([
          'outer before 1',
          'inner before 11',
          'handler request 33 headers {initial: value, a: yes, b: true}',
          'inner after 38',
          'outer after 76',
        ]),
      );
    });

    test(
      'handleServerStream hands the handler the interceptor context',
      () async {
        final endpoint = RpcCallerEndpoint(transport: _DummyTransport());
        addTearDown(() async => endpoint.close());

        final events = <String>[];
        endpoint.addInterceptor(_ServerStreamInterceptor(events));

        final stream = endpoint.handleServerStream<int, int>(
          serviceName: 'svc',
          methodName: 'serverStream',
          context: RpcContext.withHeaders({'initial': '1'}),
          direction: RpcCallDirection.outgoing,
          request: 5,
          handler: (ctx, request) {
            return Stream<int>.fromIterable([request, request + 1]).map((
              value,
            ) {
              events.add('handler emit $value headers ${ctx.headers}');
              expect(ctx.getHeader('srv'), equals('yes'));
              return value;
            });
          },
        );

        expect(await stream.toList(), equals([110, 111]));
        expect(
          events,
          equals([
            'server before 5',
            'handler emit 10 headers {initial: 1, srv: yes}',
            'server emit 10',
            'handler emit 11 headers {initial: 1, srv: yes}',
            'server emit 11',
          ]),
        );
      },
    );

    test(
      'handleClientStream lets an interceptor replace the requests',
      () async {
        final endpoint = RpcCallerEndpoint(transport: _DummyTransport());
        addTearDown(() async => endpoint.close());

        final events = <String>[];
        endpoint.addInterceptor(_ClientStreamInterceptor(events));

        final result = await endpoint.handleClientStream<int, int>(
          serviceName: 'svc',
          methodName: 'clientStream',
          context: RpcContext.withHeaders({'initial': '1'}),
          direction: RpcCallDirection.outgoing,
          requests: Stream<int>.fromIterable([1, 2, 3]),
          handler: (ctx, requests) async {
            events.add('handler ctx client=${ctx.getHeader('client')}');
            final values = await requests.cast<int>().toList();
            events.add('handler values $values');
            return values.reduce((a, b) => a + b);
          },
        );

        expect(result, equals(62));
        expect(
          events,
          equals([
            'client received 1',
            'client received 2',
            'client received 3',
            'handler ctx client=ok',
            'handler values [2, 4, 6]',
            'client response 12',
          ]),
        );
      },
    );

    test('handleBidirectionalStream maps both directions', () async {
      final endpoint = RpcCallerEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      final events = <String>[];
      endpoint.addInterceptor(_BidirectionalStreamInterceptor(events));

      final responses = endpoint.handleBidirectionalStream<int, int>(
        serviceName: 'svc',
        methodName: 'bidi',
        context: RpcContext.withHeaders({'initial': '1'}),
        direction: RpcCallDirection.outgoing,
        requests: Stream<int>.fromIterable([1, 2]),
        handler: (ctx, requests) {
          return requests.cast<int>().map((value) {
            events.add('handler saw $value headers ${ctx.headers}');
            expect(ctx.getHeader('bidi'), equals('yes'));
            return value + 100;
          });
        },
      );

      expect(await responses.toList(), equals([115, 125]));
      expect(
        events,
        equals([
          'bidi request 1',
          'handler saw 10 headers {initial: 1, bidi: yes}',
          'bidi response 110',
          'bidi request 2',
          'handler saw 20 headers {initial: 1, bidi: yes}',
          'bidi response 120',
        ]),
      );
    });
  });
}

class _DummyTransport extends IRpcTransport {
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
      Stream<RpcTransportMessage>.empty();

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
  int get lastIssuedStreamId => 0;

  @override
  bool get supportsStreamIdResume => true;

  @override
  void resumeStreamIdsAfter(int streamId) {}
}

class _OuterUnaryInterceptor extends IRpcInterceptor {
  final List<String> events;

  _OuterUnaryInterceptor(this.events);

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    final intRequest = request as int;
    events.add('outer before $intRequest');
    expect(call.context.getHeader('A'), isNull);
    final newContext = call.context.withAdditionalHeaders({'A': 'yes'});
    final response = await next(newContext, (intRequest + 10) as TRequest);
    final intResponse = response as int;
    events.add('outer after $intResponse');
    return (intResponse + 100) as TResponse;
  }
}

class _InnerUnaryInterceptor extends IRpcInterceptor {
  final List<String> events;

  _InnerUnaryInterceptor(this.events);

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    final intRequest = request as int;
    events.add('inner before $intRequest');
    expect(call.context.getHeader('A'), equals('yes'));
    final newContext = call.context.withAdditionalHeaders({'B': 'true'});
    final response = await next(newContext, (intRequest * 3) as TRequest);
    final intResponse = response as int;
    events.add('inner after $intResponse');
    return (intResponse * 2) as TResponse;
  }
}

class _ServerStreamInterceptor extends IRpcInterceptor {
  final List<String> events;

  _ServerStreamInterceptor(this.events);

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    final intRequest = request as int;
    events.add('server before $intRequest');
    final newContext = call.context.withAdditionalHeaders({'srv': 'yes'});
    final Stream<int> upstream =
        await next(newContext, (intRequest * 2) as TRequest) as Stream<int>;
    return upstream.map<TResponse>((value) {
      events.add('server emit $value');
      return (value + 100) as TResponse;
    });
  }
}

class _ClientStreamInterceptor extends IRpcInterceptor {
  final List<String> events;

  _ClientStreamInterceptor(this.events);

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    final values = <int>[];
    await for (final request in requests) {
      final intRequest = request as int;
      events.add('client received $intRequest');
      values.add(intRequest * 2);
    }

    final newContext = call.context.withAdditionalHeaders({'client': 'ok'});
    final response = await next(
      newContext,
      Stream<int>.fromIterable(
        values,
      ).map<TRequest>((value) => value as TRequest),
    );
    events.add('client response $response');
    return ((response as int) + 50) as TResponse;
  }
}

class _BidirectionalStreamInterceptor extends IRpcInterceptor {
  final List<String> events;

  _BidirectionalStreamInterceptor(this.events);

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    final newContext = call.context.withAdditionalHeaders({'bidi': 'yes'});
    final forwardedRequests = requests.map<TRequest>((value) {
      final intRequest = value as int;
      events.add('bidi request $intRequest');
      return (intRequest * 10) as TRequest;
    });

    final Stream<int> upstream =
        await next(newContext, forwardedRequests) as Stream<int>;
    return upstream.map<TResponse>((value) {
      events.add('bidi response $value');
      return (value + 5) as TResponse;
    });
  }
}
