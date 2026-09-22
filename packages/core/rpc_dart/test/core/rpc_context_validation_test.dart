// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// End-to-end validation of the RPC context: that it behaves correctly across
/// every method shape, and at the edges.
void main() {
  group('RPC Context Validation', () {
    late RpcCallerEndpoint clientEndpoint;
    late RpcResponderEndpoint serverEndpoint;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late ValidationServiceContract validationService;

    setUp(() {
      final (client, server) = RpcInMemoryTransport.pair();
      clientTransport = client;
      serverTransport = server;

      clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
      serverEndpoint = RpcResponderEndpoint(transport: serverTransport);

      validationService = ValidationServiceContract();
      serverEndpoint.registerServiceContract(validationService);
      serverEndpoint.start();
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
    });

    group('carrying headers', () {
      test('every kind of header crosses intact', () async {
        // Arrange
        final context = RpcContext.withHeaders({
          'user-id': 'test-user-123',
          'authorization': 'Bearer token-456',
          'custom-header': 'custom-value',
          'special-chars': 'value with spaces & symbols!',
          'numbers': '12345',
        });

        // Act
        final result = await clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'ValidationService',
          methodName: 'ValidateHeaders',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'test'.rpc,
          context: context,
        );

        // Assert
        final response = result.value;
        expect(response, contains('user-id:test-user-123'));
        expect(response, contains('authorization:Bearer token-456'));
        expect(response, contains('custom-header:custom-value'));
        expect(
          response,
          contains('special-chars:value with spaces & symbols!'),
        );
        expect(response, contains('numbers:12345'));
      });

      test('a non-ASCII header value is refused on send', () async {
        // Per gRPC, ASCII metadata values must be printable ASCII; non-ASCII /
        // binary must use a -bin key. Sending a unicode header value must fail
        // rather than silently corrupt on the wire.
        final context = RpcContext.withHeaders({'x-name': 'тест с unicode 🚀'});

        await expectLater(
          clientEndpoint.unaryRequest<RpcString, RpcString>(
            serviceName: 'ValidationService',
            methodName: 'ValidateHeaders',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'test'.rpc,
            context: context,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('the system headers behave', () async {
        // Arrange
        final context = RpcContext.withTraceId('test-trace-123');

        // Act
        final result = await clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'ValidationService',
          methodName: 'ValidateSystemHeaders',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'test'.rpc,
          context: context,
        );

        // Assert
        final response = result.value;
        expect(response, contains('trace-id:test-trace-123'));
        expect(response, contains('request-id:req_')); // The request-id format.
      });
    });

    group('deadline and timeout', () {
      test('a context with a timeout works', () async {
        // Arrange
        final context = RpcContext.withTimeout(Duration(milliseconds: 10));

        // Act & Assert
        await expectLater(
          clientEndpoint.unaryRequest<RpcString, RpcString>(
            serviceName: 'ValidationService',
            methodName: 'SlowOperation',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'slow'.rpc,
            context: context,
          ),
          throwsA(
            anyOf(isA<TimeoutException>(), isA<RpcDeadlineExceededException>()),
          ),
        );
      });

      test('a deadline is checked before the call goes out', () async {
        // Arrange: a deadline that has already passed.
        final expiredDeadline = DateTime.now().subtract(Duration(hours: 1));
        final context = RpcContext.withDeadline(expiredDeadline);

        // Act & Assert
        expect(
          () => clientEndpoint.unaryRequest<RpcString, RpcString>(
            serviceName: 'ValidationService',
            methodName: 'FastOperation',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'fast'.rpc,
            context: context,
          ),
          throwsA(isA<RpcDeadlineExceededException>()),
        );
      });
    });

    group('Cancellation Token', () {
      test('cancelling before the call throws', () async {
        // Arrange
        final token = RpcCancellationToken.cancelled('Pre-cancelled');
        final context = RpcContext.withCancellation(token);

        // Act & Assert
        expect(
          () => clientEndpoint.unaryRequest<RpcString, RpcString>(
            serviceName: 'ValidationService',
            methodName: 'FastOperation',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'test'.rpc,
            context: context,
          ),
          throwsA(isA<RpcCancelledException>()),
        );
      });

      test('cancelling mid-flight interrupts the operation', () async {
        // Arrange
        final token = RpcCancellationToken();
        final context = RpcContext.withCancellation(token);

        // Cancel once the handler is under way.
        Timer(Duration(milliseconds: 1), () {
          token.cancel('Operation cancelled during execution');
        });

        // Act & Assert
        await expectLater(
          clientEndpoint.unaryRequest<RpcString, RpcString>(
            serviceName: 'ValidationService',
            methodName: 'LongOperation',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'long'.rpc,
            context: context,
          ),
          throwsA(isA<RpcCancelledException>()),
        );
      });
    });

    group('server streaming with a context', () {
      test('the context reaches the server-stream handler', () async {
        // Arrange
        final context = RpcContext.withHeaders({
          'stream-size': '3',
          'stream-prefix': 'test-prefix',
        }).withTraceId('server-stream-trace');

        // Act
        final responses = <RpcString>[];
        await for (final response
            in clientEndpoint.serverStream<RpcString, RpcString>(
              serviceName: 'ValidationService',
              methodName: 'GenerateWithContext',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'generate'.rpc,
              context: context,
            )) {
          responses.add(response);
        }

        // Assert
        expect(responses.length, equals(3));
        expect(responses.every((r) => r.value.contains('test-prefix')), isTrue);
        expect(
          responses.every((r) => r.value.contains('server-stream-trace')),
          isTrue,
        );
      });
    });

    group('client streaming with a context', () {
      test('the context reaches the client-stream handler', () async {
        // Arrange
        final context = RpcContext.withHeaders({
          'aggregation-type': 'count',
          'multiplier': '2',
        }).withTraceId('client-stream-trace');

        final requestsController = StreamController<RpcString>();
        final clientStreamFn = clientEndpoint
            .clientStream<RpcString, RpcString>(
              serviceName: 'ValidationService',
              methodName: 'AggregateWithContext',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              context: context,
            );

        // Act
        final responsePromise = clientStreamFn(requestsController.stream);

        requestsController.add('item1'.rpc);
        requestsController.add('item2'.rpc);
        requestsController.add('item3'.rpc);
        await requestsController.close();

        final response = await responsePromise;

        // Assert
        expect(
          response.value,
          contains('count:6'),
        ); // 3 items * multiplier 2 = 6
        expect(response.value, contains('multiplier:2'));
        expect(response.value, contains('client-stream-trace'));
      });
    });

    group('bidirectional streaming with a context', () {
      test('the context reaches the bidirectional handler', () async {
        // Arrange
        final context = RpcContext.withHeaders({
          'echo-prefix': 'ECHO',
          'transform': 'uppercase',
        }).withTraceId('bidirectional-trace');

        final requestController = StreamController<RpcString>();
        final responses = <RpcString>[];

        // Act
        final responseStream = clientEndpoint
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'ValidationService',
              methodName: 'ProcessWithContext',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              requests: requestController.stream,
              context: context,
            );

        final subscription = responseStream.listen((response) {
          responses.add(response);
        });

        requestController.add('hello'.rpc);
        await Future<void>.delayed(
          Duration(milliseconds: 1),
        ); // Let the handler run.
        requestController.add('world'.rpc);
        await Future<void>.delayed(
          Duration(milliseconds: 1),
        ); // Let the handler run.
        await requestController.close();

        // Wait longer, for the answers to arrive.
        await Future<void>.delayed(Duration(milliseconds: 1));
        await subscription.cancel();

        // Assert
        expect(responses.length, equals(2));
        expect(responses[0].value, contains('ECHO:HELLO'));
        expect(responses[1].value, contains('ECHO:WORLD'));
        expect(
          responses.every((r) => r.value.contains('bidirectional-trace')),
          isTrue,
        );
      });
    });

    group('context values, which are local', () {
      test('context values do not go over the wire', () async {
        // Arrange
        final context = RpcContext.withHeaders({
          'visible-header': 'should-appear',
        }).withValue('secret-value', 'should-not-appear');

        // Act
        final result = await clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'ValidationService',
          methodName: 'CheckContextValues',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'test'.rpc,
          context: context,
        );

        // Assert
        final response = result.value;
        expect(response, contains('visible-header:should-appear'));
        expect(response, isNot(contains('should-not-appear')));
        expect(
          response,
          contains('context-values-count:0'),
        ); // The server must not see the context values.
      });
    });

    group('Edge Cases', () {
      test('an empty context breaks nothing', () async {
        // Arrange
        final context = RpcContext.empty();

        // Act
        final result = await clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'ValidationService',
          methodName: 'ValidateHeaders',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'test'.rpc,
          context: context,
        );

        // Assert
        expect(result.value, isNotEmpty);
      });

      test('a null context works', () async {
        // Act
        final result = await clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'ValidationService',
          methodName:
              'ValidateSystemHeaders', // This method always makes a requestId.
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'test'.rpc,
          context: null,
        );

        // Assert
        expect(result.value, isNotEmpty); // At minimum, a requestId.
        expect(
          result.value,
          contains('request-id:req_'),
        ); // The base requestId must be there.
      });

      test('a very long header value works', () async {
        // Arrange
        final longValue = 'x' * 1000; // A 1 KB header.
        final context = RpcContext.withHeaders({'long-header': longValue});

        // Act
        final result = await clientEndpoint.unaryRequest<RpcString, RpcString>(
          serviceName: 'ValidationService',
          methodName: 'ValidateHeaders',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: 'test'.rpc,
          context: context,
        );

        // Assert
        expect(result.value, contains('long-header:$longValue'));
      });
    });
  });
}

/// The service these tests drive.
final class ValidationServiceContract extends RpcResponderContract {
  ValidationServiceContract() : super('ValidationService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ValidateHeaders',
      handler: _validateHeaders,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Checks that headers are carried',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ValidateSystemHeaders',
      handler: _validateSystemHeaders,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Checks the system headers',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'SlowOperation',
      handler: _slowOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A slow operation, for the timeout tests',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'FastOperation',
      handler: _fastOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A fast operation',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'LongOperation',
      handler: _longOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A long operation, for the cancellation tests',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'CheckContextValues',
      handler: _checkContextValues,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Checks that context values stay off the wire',
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GenerateWithContext',
      handler: _generateWithContext,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Generates data from the context',
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'AggregateWithContext',
      handler: _aggregateWithContext,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Aggregates data using the context',
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'ProcessWithContext',
      handler: _processWithContext,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Processes a stream using the context',
    );
  }

  Future<RpcString> _validateHeaders(
    RpcString request, {
    RpcContext? context,
  }) async {
    final headers = context?.headers ?? <String, String>{};
    final result = headers.entries.map((e) => '${e.key}:${e.value}').join('|');
    return result.rpc;
  }

  Future<RpcString> _validateSystemHeaders(
    RpcString request, {
    RpcContext? context,
  }) async {
    final traceId = context?.traceId ?? '';
    final requestId = context?.requestId;
    return 'trace-id:$traceId|request-id:$requestId'.rpc;
  }

  Future<RpcString> _slowOperation(
    RpcString request, {
    RpcContext? context,
  }) async {
    await Future<void>.delayed(
      Duration(seconds: 5),
    ); // Longer than the timeout the test sets.
    return 'slow-result'.rpc;
  }

  Future<RpcString> _fastOperation(
    RpcString request, {
    RpcContext? context,
  }) async {
    return 'fast-result'.rpc;
  }

  Future<RpcString> _longOperation(
    RpcString request, {
    RpcContext? context,
  }) async {
    // Check for cancellation every 10 ms.
    for (int i = 0; i < 1000; i++) {
      context?.cancellationToken?.throwIfCancelled();
      await Future<void>.delayed(Duration(milliseconds: 1));
    }
    return 'long-result'.rpc;
  }

  Future<RpcString> _checkContextValues(
    RpcString request, {
    RpcContext? context,
  }) async {
    final headers = context?.headers ?? <String, String>{};
    final values = context?.values ?? <Object, Object>{};
    final headersList = headers.entries
        .map((e) => '${e.key}:${e.value}')
        .join('|');
    return '$headersList|context-values-count:${values.length}'.rpc;
  }

  Stream<RpcString> _generateWithContext(
    RpcString request, {
    RpcContext? context,
  }) async* {
    final size = int.parse(context?.getHeader('stream-size') ?? '1');
    final prefix = context?.getHeader('stream-prefix') ?? 'default';
    final traceId = context?.traceId ?? 'no-trace';

    for (int i = 0; i < size; i++) {
      yield '$prefix-$i-$traceId'.rpc;
    }
  }

  Future<RpcString> _aggregateWithContext(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async {
    final aggregationType = context?.getHeader('aggregation-type') ?? 'concat';
    final multiplier = int.parse(context?.getHeader('multiplier') ?? '1');
    final traceId = context?.traceId ?? 'no-trace';

    final items = await requests.toList();

    if (aggregationType == 'count') {
      final count = items.length * multiplier;
      return 'count:$count|multiplier:$multiplier|trace:$traceId'.rpc;
    }

    return 'concat:${items.map((i) => i.value).join(',')}|trace:$traceId'.rpc;
  }

  Stream<RpcString> _processWithContext(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async* {
    final prefix = context?.getHeader('echo-prefix') ?? 'ECHO';
    final transform = context?.getHeader('transform') ?? 'none';
    final traceId = context?.traceId ?? 'no-trace';

    await for (final request in requests) {
      var processed = request.value;

      if (transform == 'uppercase') {
        processed = processed.toUpperCase();
      }

      yield '$prefix:$processed|trace:$traceId'.rpc;
    }
  }
}
