// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await UnaryRpcExample.run();
}

/// A unary RPC call (one request, one response), using contracts and
/// [RpcContext].
class UnaryRpcExample {
  static Future<void> run() async {
    // logging configured via LogController
    print('\n=== Unary RPC with contracts and context ===\n');
    // The transports.
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    // The server endpoint, with its contracts registered.
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'Server',
    );
    final multiService = MultiServiceResponder();
    serverEndpoint.registerServiceContract(multiService);
    serverEndpoint.start();
    // The client endpoint.
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'Client',
    );
    final client = MultiServiceCaller(clientEndpoint);
    try {
      // 1: a plain call, no context.
      print('\n--- 1: a plain call ---');
      final response1 = await client.sayHello('Hello'.rpc);
      print('CLIENT: response: "$response1"');
      // 2: a call carrying a context.
      print('\n--- 2: a call with a context ---');
      final context2 = RpcContextUtils.withBearerToken('secret-token-123')
          .withAdditionalHeaders({'user-id': 'user-456'})
          .withTraceId('trace-${DateTime.now().millisecondsSinceEpoch}');
      final response2 = await client.getCurrentTime(
        'Time'.rpc,
        context: context2,
      );
      print('CLIENT: response: "$response2"');
      // 3: a call with a deadline.
      print('\n--- 3: a call with a timeout ---');
      final timeoutContext = RpcContext.withTimeout(
        Duration(milliseconds: 500),
      ).withValue('request-type', 'health-check');
      final response3 = await client.checkHealth(
        'Status'.rpc,
        context: timeoutContext,
      );
      print('CLIENT: response: "$response3"');
      // 4: a call that fails.
      print('\n--- 4: error handling ---');
      try {
        await client.throwError('Error'.rpc);
      } catch (e) {
        print('CLIENT: the expected error arrived: $e');
      }
      // 5: a call that is cancelled.
      print('\n--- 5: cancelling an operation ---');
      try {
        final cancellationToken = RpcCancellationToken();
        final cancelContext = RpcContext.withCancellation(cancellationToken);
        // Cancel after 100ms.
        Future<void>.delayed(Duration(milliseconds: 100), () {
          print('CLIENT: cancelling');
          cancellationToken.cancel('User cancelled');
        });
        await client.longOperation(
          'A long operation'.rpc,
          context: cancelContext,
        );
      } catch (e) {
        print('CLIENT: cancelled: $e');
      }
    } catch (e, stackTrace) {
      print('ERROR: $e');
      print('StackTrace: $stackTrace');
    } finally {
      await serverEndpoint.close();
      await clientEndpoint.close();
    }
    print('\n=== Example finished ===\n');
  }
}

//
// THE SERVER CONTRACT
//
abstract interface class IMultiServiceContract implements IRpcContract {
  Future<RpcString> sayHello(RpcString message);
  Future<RpcString> getCurrentTime(RpcString message);
  Future<RpcString> checkHealth(RpcString message);
  Future<RpcString> throwError(RpcString message);
  Future<RpcString> longOperation(RpcString message);
}

final class MultiServiceResponder extends RpcResponderContract
    implements IMultiServiceContract {
  MultiServiceResponder() : super('MultiService');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'SayHello',
      handler: sayHello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A plain greeting',
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetCurrentTime',
      handler: getCurrentTime,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Returns the current time',
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'CheckHealth',
      handler: checkHealth,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Reports the service health',
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ThrowError',
      handler: throwError,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Raises an error, for testing',
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'LongOperation',
      handler: longOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A long operation, for testing cancellation',
    );
  }

  @override
  Future<RpcString> sayHello(RpcString message, {RpcContext? context}) async {
    final logger = LogScope.noop;
    logger.info('request: ${message.value}');
    logger.info('context: $context');
    await Future<void>.delayed(Duration(milliseconds: 10));
    return 'Hello! This is the server answering: ${message.value}'.rpc;
  }

  @override
  Future<RpcString> getCurrentTime(
    RpcString message, {
    RpcContext? context,
  }) async {
    final logger = LogScope.noop;
    logger.info('time request: ${message.value}');
    logger.info('context: $context');
    final userId = context?.getHeader('user-id');
    final traceId = context?.traceId;
    await Future<void>.delayed(Duration(milliseconds: 20));
    return 'Current time: ${DateTime.now()} [user: $userId, trace: $traceId]'
        .rpc;
  }

  @override
  Future<RpcString> checkHealth(
    RpcString message, {
    RpcContext? context,
  }) async {
    final logger = LogScope.noop;
    logger.info('health check: ${message.value}');
    logger.info('context: $context');
    final requestType = context?.getValue<String>('request-type');
    context?.cancellationToken?.throwIfCancelled();
    await Future<void>.delayed(Duration(milliseconds: 30));
    return 'All systems nominal [$requestType]'.rpc;
  }

  @override
  Future<RpcString> throwError(RpcString message, {RpcContext? context}) async {
    final logger = LogScope.noop;
    logger.info('raising an error: ${message.value}');
    logger.info('context: $context');
    throw Exception('Test error: ${message.value}');
  }

  @override
  Future<RpcString> longOperation(
    RpcString message, {
    RpcContext? context,
  }) async {
    final logger = LogScope.noop;
    logger.info('starting a long operation: ${message.value}');
    logger.info('context: $context');
    for (int i = 0; i < 100; i++) {
      context?.cancellationToken?.throwIfCancelled();
      await Future<void>.delayed(Duration(milliseconds: 10));
      if (i % 20 == 0) {
        logger.internal('progress: $i%');
      }
    }
    return 'The long operation finished: ${message.value}'.rpc;
  }
}

//
// THE CLIENT CONTRACT
//
final class MultiServiceCaller extends RpcCallerContract
    implements IMultiServiceContract {
  MultiServiceCaller(RpcCallerEndpoint endpoint)
    : super('MultiService', endpoint);
  @override
  Future<RpcString> sayHello(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'SayHello',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> getCurrentTime(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetCurrentTime',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> checkHealth(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'CheckHealth',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> throwError(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'ThrowError',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> longOperation(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'LongOperation',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }
}
