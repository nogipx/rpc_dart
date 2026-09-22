// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await ServerStreamingExample.run();
}

/// Server streaming (one request, many responses), using contracts and
/// [RpcContext].
class ServerStreamingExample {
  static Future<void> run() async {
    // logging configured via LogController
    print('\n=== Server streaming with contracts ===\n');
    // The transports.
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    // The server endpoint, with its contract registered.
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'Server',
    );
    final service = DataStreamServiceResponder();
    serverEndpoint.registerServiceContract(service);
    serverEndpoint.start();
    // The client endpoint.
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'Client',
    );
    final client = DataStreamServiceCaller(clientEndpoint);
    try {
      // 1: a plain server stream.
      print('\n--- 1: a plain server stream ---');
      final context1 = RpcContext.empty()
          .withTraceId('server-stream-trace-123')
          .withValue('stream-type', 'simple');
      await for (final response in client.getServerStream(
        'Send me data'.rpc,
        context: context1,
      )) {
        print('CLIENT: response: "$response"');
      }
      // 2: a stream of numbers.
      print('\n--- 2: a stream of numbers ---');
      final context2 = RpcContext.empty()
          .withTraceId('numbers-stream-trace-456')
          .withAdditionalHeaders({'count': '10', 'delay': '100'});
      await for (final number in client.getNumberStream(
        5.rpc,
        context: context2,
      )) {
        print('CLIENT: number: $number');
      }
      // 3: a server stream that gets cancelled.
      print('\n--- 3: cancelling a server stream ---');
      final cancellationToken = RpcCancellationToken();
      final cancelContext = RpcContext.withCancellation(
        cancellationToken,
      ).withValue('stream-type', 'long-running');
      // Cancel after 200ms.
      Future<void>.delayed(Duration(milliseconds: 200), () {
        print('CLIENT: cancelling the stream');
        cancellationToken.cancel('User cancelled');
      });
      try {
        await for (final response in client.getLongRunningStream(
          'A long stream'.rpc,
          context: cancelContext,
        )) {
          print('CLIENT: response: "$response"');
        }
      } catch (e) {
        print('CLIENT: the stream was cancelled: $e');
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
abstract interface class IDataStreamServiceContract implements IRpcContract {
  Stream<RpcString> getServerStream(RpcString request);
  Stream<RpcInt> getNumberStream(RpcInt count);
  Stream<RpcString> getLongRunningStream(RpcString request);
}

final class DataStreamServiceResponder extends RpcResponderContract
    implements IDataStreamServiceContract {
  DataStreamServiceResponder() : super('DataStreamService');
  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetServerStream',
      handler: getServerStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Answers one request with a stream of strings',
    );
    addServerStreamMethod<RpcInt, RpcInt>(
      methodName: 'GetNumberStream',
      handler: getNumberStream,
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      description: 'Sends a stream of numbers',
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetLongRunningStream',
      handler: getLongRunningStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A long stream, for testing cancellation',
    );
  }

  @override
  Stream<RpcString> getServerStream(
    RpcString request, {
    RpcContext? context,
  }) async* {
    final logger = LogScope.noop;
    logger.info('request: ${request.value}');
    logger.info('context: $context');
    final streamType = context?.getValue<String>('stream-type');
    logger.info('stream type: $streamType');
    // A few responses, paced.
    for (int i = 1; i <= 5; i++) {
      context?.cancellationToken?.throwIfCancelled();
      final response = 'Response #$i to "${request.value}"';
      logger.internal('sending: $response');
      yield response.rpc;
      await Future<void>.delayed(Duration(milliseconds: 50));
    }
    logger.info('the response stream is finished');
  }

  @override
  Stream<RpcInt> getNumberStream(RpcInt count, {RpcContext? context}) async* {
    final logger = LogScope.noop;
    logger.info('number request: ${count.value}');
    logger.info('context: $context');
    final requestedCount = count.value;
    final countHeader = context?.getHeader('count');
    final delayHeader = context?.getHeader('delay');
    final actualCount = countHeader != null
        ? int.parse(countHeader)
        : requestedCount;
    final delay = delayHeader != null ? int.parse(delayHeader) : 50;
    logger.info('sending $actualCount numbers, ${delay}ms apart');
    for (int i = 0; i < actualCount; i++) {
      context?.cancellationToken?.throwIfCancelled();
      logger.internal('sending number: $i');
      yield i.rpc;
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
    logger.info('the number stream is finished');
  }

  @override
  Stream<RpcString> getLongRunningStream(
    RpcString request, {
    RpcContext? context,
  }) async* {
    final logger = LogScope.noop;
    logger.info('starting a long stream: ${request.value}');
    logger.info('context: $context');
    try {
      // 20 messages, 100ms apart: two seconds in total.
      for (int i = 1; i <= 20; i++) {
        context?.cancellationToken?.throwIfCancelled();
        final response = 'Long response #$i for "${request.value}"';
        logger.internal('sending: $response');
        yield response.rpc;
        await Future<void>.delayed(Duration(milliseconds: 100));
      }
      logger.info('the long stream is finished');
    } catch (e) {
      logger.warning('the long stream was cancelled: $e');
      rethrow;
    }
  }
}

//
// THE CLIENT CONTRACT
//
final class DataStreamServiceCaller extends RpcCallerContract
    implements IDataStreamServiceContract {
  DataStreamServiceCaller(RpcCallerEndpoint endpoint)
    : super('DataStreamService', endpoint);
  @override
  Stream<RpcString> getServerStream(RpcString request, {RpcContext? context}) {
    return callServerStream<RpcString, RpcString>(
      methodName: 'GetServerStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: request,
      context: context,
    );
  }

  @override
  Stream<RpcInt> getNumberStream(RpcInt count, {RpcContext? context}) {
    return callServerStream<RpcInt, RpcInt>(
      methodName: 'GetNumberStream',
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      request: count,
      context: context,
    );
  }

  @override
  Stream<RpcString> getLongRunningStream(
    RpcString request, {
    RpcContext? context,
  }) {
    return callServerStream<RpcString, RpcString>(
      methodName: 'GetLongRunningStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: request,
      context: context,
    );
  }
}
