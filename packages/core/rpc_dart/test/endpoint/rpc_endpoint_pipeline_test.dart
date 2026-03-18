// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpointBase middleware pipeline', () {
    test('handleUnary runs middlewares and interceptors in order', () async {
      final endpoint = _TestEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      final events = <String>[];
      final mw1ResponseContexts = <RpcMiddlewareContext>[];
      final mw2ResponseContexts = <RpcMiddlewareContext>[];

      endpoint
        ..addMiddleware(
          _RecordingMiddleware(
            name: 'mw1',
            events: events,
            onRequest: (context, value) => (value as int) + 1,
            onResponse: (context, value) {
              mw1ResponseContexts.add(context);
              expect(context.context.getHeader('A'), equals('yes'));
              expect(context.context.getHeader('B'), equals('true'));
              expect(context.context.getHeader('C'), equals('done'));
              return (value as int) + 1;
            },
          ),
        )
        ..addMiddleware(
          _RecordingMiddleware(
            name: 'mw2',
            events: events,
            asyncRequest: true,
            asyncResponse: true,
            onRequest: (context, value) => (value as int) * 2,
            onResponse: (context, value) {
              mw2ResponseContexts.add(context);
              expect(context.context.getHeader('A'), equals('yes'));
              expect(context.context.getHeader('B'), equals('true'));
              expect(context.context.getHeader('C'), equals('done'));
              return (value as int) * 2;
            },
          ),
        )
        ..addInterceptor(_OuterUnaryInterceptor(events))
        ..addInterceptor(_InnerUnaryInterceptor(events));

      final baseContext = RpcContext.withHeaders({'initial': 'value'});

      final result = await endpoint.handleUnary<int, int>(
        serviceName: 'svc',
        methodName: 'method',
        context: baseContext,
        request: 1,
        handler: (ctx, request) async {
          events.add('handler request $request headers ${ctx.headers}');
          expect(ctx.getHeader('A'), equals('yes'));
          expect(ctx.getHeader('B'), equals('true'));
          return request + 5;
        },
      );

      expect(result, equals(389));
      expect(
        events,
        equals(
          [
            'mw1 request 1',
            'mw2 request 2',
            'outer before 4',
            'inner before 14',
            'handler request 42 headers {initial: value, a: yes, b: true}',
            'inner after 47',
            'outer after 94',
            'mw2 response 194',
            'mw1 response 388',
          ],
        ),
      );

      expect(mw1ResponseContexts, hasLength(1));
      expect(mw2ResponseContexts, hasLength(1));
      expect(
        identical(
          mw1ResponseContexts.single.context,
          mw2ResponseContexts.single.context,
        ),
        isTrue,
      );
      expect(mw1ResponseContexts.single.serviceName, equals('svc'));
      expect(mw1ResponseContexts.single.methodName, equals('method'));
      expect(mw1ResponseContexts.single.endpoint, same(endpoint));
    });

    test('handleServerStream applies middleware to every response item',
        () async {
      final endpoint = _TestEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      final events = <String>[];
      final responseContexts = <RpcMiddlewareContext>[];

      endpoint
        ..addMiddleware(
          _RecordingMiddleware(
            name: 'mw',
            events: events,
            onRequest: (context, value) => (value as int) + 1,
            onResponse: (context, value) {
              responseContexts.add(context);
              expect(context.context.getHeader('srv'), equals('yes'));
              expect(context.context.getHeader('initial'), equals('1'));
              return (value as int) * 10;
            },
          ),
        )
        ..addInterceptor(_ServerStreamInterceptor(events));

      final stream = endpoint.handleServerStream<int, int>(
        serviceName: 'svc',
        methodName: 'serverStream',
        context: RpcContext.withHeaders({'initial': '1'}),
        request: 5,
        handler: (ctx, request) {
          return Stream<int>.fromIterable([request, request + 1]).map((value) {
            events.add('handler emit $value headers ${ctx.headers}');
            expect(ctx.getHeader('srv'), equals('yes'));
            return value;
          });
        },
      );

      final results = await stream.toList();
      expect(results, equals([1120, 1130]));
      expect(
        events,
        equals(
          [
            'mw request 5',
            'server before 6',
            'handler emit 12 headers {initial: 1, srv: yes}',
            'server emit 12',
            'mw response 112',
            'handler emit 13 headers {initial: 1, srv: yes}',
            'server emit 13',
            'mw response 113',
          ],
        ),
      );

      expect(responseContexts, hasLength(2));
      expect(
        responseContexts.every(
          (ctx) => identical(ctx.context, responseContexts.first.context),
        ),
        isTrue,
      );
    });

    test('handleClientStream normalizes incoming stream and updates context',
        () async {
      final endpoint = _TestEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      final events = <String>[];
      final responseContexts = <RpcMiddlewareContext>[];

      endpoint
        ..addMiddleware(
          _RecordingMiddleware(
            name: 'mw',
            events: events,
            onRequest: (context, value) => (value as int) + 1,
            onResponse: (context, value) {
              responseContexts.add(context);
              expect(context.context.getHeader('client'), equals('ok'));
              return (value as int) + 2;
            },
          ),
        )
        ..addInterceptor(_ClientStreamInterceptor(events));

      final result = await endpoint.handleClientStream<int, int>(
        serviceName: 'svc',
        methodName: 'clientStream',
        context: RpcContext.withHeaders({'initial': '1'}),
        requests: Stream<int>.fromIterable([1, 2, 3]),
        handler: (ctx, requests) async {
          events.add('handler ctx client=${ctx.getHeader('client')}');
          final values = await requests.cast<int>().toList();
          events.add('handler values $values');
          expect(ctx.getHeader('client'), equals('ok'));
          return values.reduce((a, b) => a + b);
        },
      );

      expect(result, equals(70));
      expect(events, hasLength(10));
      expect(
        events,
        containsAllInOrder([
          'mw request 1',
          'client received 2',
          'mw request 2',
          'client received 3',
          'mw request 3',
          'client received 4',
          'handler ctx client=ok',
          'handler values [4, 6, 8]',
          'client response 18',
          'mw response 68',
        ]),
      );

      int indexOf(String value) => events.indexOf(value);
      expect(indexOf('mw request 1'), lessThan(indexOf('client received 2')));
      expect(indexOf('mw request 2'), lessThan(indexOf('client received 3')));
      expect(indexOf('mw request 3'), lessThan(indexOf('client received 4')));

      expect(responseContexts, hasLength(1));
      expect(responseContexts.single.context.getHeader('client'), equals('ok'));
    });

    test('handleBidirectionalStream applies middleware to both directions',
        () async {
      final endpoint = _TestEndpoint(transport: _DummyTransport());
      addTearDown(() async => endpoint.close());

      final events = <String>[];
      final responseContexts = <RpcMiddlewareContext>[];

      endpoint
        ..addMiddleware(
          _RecordingMiddleware(
            name: 'mw',
            events: events,
            onRequest: (context, value) => (value as int) + 1,
            onResponse: (context, value) {
              responseContexts.add(context);
              expect(context.context.getHeader('bidi'), equals('yes'));
              return (value as int) * 2;
            },
          ),
        )
        ..addInterceptor(_BidirectionalStreamInterceptor(events));

      final responses = endpoint.handleBidirectionalStream<int, int>(
        serviceName: 'svc',
        methodName: 'bidi',
        context: RpcContext.withHeaders({'initial': '1'}),
        requests: Stream<int>.fromIterable([1, 2]),
        handler: (ctx, requests) {
          return requests.cast<int>().map((value) {
            events.add('handler saw $value headers ${ctx.headers}');
            expect(ctx.getHeader('bidi'), equals('yes'));
            return value + 100;
          });
        },
      );

      final result = await responses.toList();
      expect(result, equals([250, 270]));
      expect(events, hasLength(10));
      expect(
        events,
        containsAllInOrder([
          'mw request 1',
          'bidi request 2',
          'mw response 125',
          'mw request 2',
          'bidi request 3',
          'mw response 135',
        ]),
      );

      final firstRequestIndex = events.indexOf('mw request 1');
      final firstForwardIndex = events.indexOf('bidi request 2');
      expect(firstRequestIndex, lessThan(firstForwardIndex));

      final secondRequestIndex = events.indexOf('mw request 2');
      final secondForwardIndex = events.lastIndexOf('bidi request 3');
      expect(secondRequestIndex, lessThan(secondForwardIndex));

      expect(responseContexts, hasLength(2));
      expect(responseContexts.first.context.getHeader('bidi'), equals('yes'));
      expect(responseContexts.last.context.getHeader('bidi'), equals('yes'));
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
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'DummyTransport');
}

base class _TestEndpoint extends RpcEndpointBase {
  _TestEndpoint({required super.transport});

  final RpcLogger _logger = const _NoopLogger();

  @override
  RpcLogger get logger => _logger;
}

class _NoopLogger implements RpcLogger {
  final String _name;

  const _NoopLogger([this._name = 'TestLogger']);

  @override
  String get name => _name;

  @override
  RpcLogger child(String childName, {String? label}) {
    return _NoopLogger('$_name.$childName');
  }

  Future<void> _complete() async {}

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
      _complete();

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
      _complete();

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
      _complete();

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
      _complete();

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
      _complete();

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
      _complete();

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
      _complete();
}

class _RecordingMiddleware extends IRpcMiddleware {
  final String name;
  final List<String> events;
  final dynamic Function(RpcMiddlewareContext context, dynamic value) onRequest;
  final dynamic Function(RpcMiddlewareContext context, dynamic value)
      onResponse;
  final bool asyncRequest;
  final bool asyncResponse;

  _RecordingMiddleware({
    required this.name,
    required this.events,
    required this.onRequest,
    required this.onResponse,
    this.asyncRequest = false,
    this.asyncResponse = false,
  });

  @override
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext call,
    TRequest request,
  ) {
    events.add('$name request $request');
    final result = onRequest(call, request);
    if (asyncRequest) {
      return Future<TRequest>.value(result as TRequest);
    }
    return result as TRequest;
  }

  @override
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext call,
    TResponse response,
  ) {
    events.add('$name response $response');
    final result = onResponse(call, response);
    if (asyncResponse) {
      return Future<TResponse>.value(result as TResponse);
    }
    return result as TResponse;
  }
}

class _OuterUnaryInterceptor extends IRpcInterceptor {
  final List<String> events;

  _OuterUnaryInterceptor(this.events);

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
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
    RpcMiddlewareContext call,
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
    call.updateContext(
      call.context.withAdditionalHeaders({'C': 'done'}),
    );
    return (intResponse * 2) as TResponse;
  }
}

class _ServerStreamInterceptor extends IRpcInterceptor {
  final List<String> events;

  _ServerStreamInterceptor(this.events);

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
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
    RpcMiddlewareContext call,
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
      Stream<int>.fromIterable(values)
          .map<TRequest>((value) => value as TRequest),
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
    RpcMiddlewareContext call,
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
