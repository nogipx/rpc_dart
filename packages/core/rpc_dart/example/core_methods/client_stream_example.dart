// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await ClientStreamingExample.run();
}

/// Client streaming: many requests, one response.
///
/// Shows a client sending a stream of requests and receiving a single answer.
class ClientStreamingExample {
  /// Runs the demonstration.
  static Future<void> run() async {
    // logging configured via LogController
    print('\n=== Client streaming (N requests -> 1 response) ===\n');
    // A connected pair of transports, one end each.
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    // The server endpoint.
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'ClientStreamServer',
    );
    // The client endpoint.
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'ClientStreamClient',
    );
    // Register the server contract.
    final serverContract = DataAggregatorResponder();
    serverEndpoint.registerServiceContract(serverContract);
    serverEndpoint.start();
    // The client contract.
    final client = DataAggregatorCaller(clientEndpoint);
    try {
      // 1: aggregating text messages.
      print('\n--- 1: aggregating text messages ---');
      final context1 = RpcContextUtils.withTracing(
        traceId: 'client-stream-123',
      ).withValue('aggregation-type', 'text');
      final messages = [
        'Message 1: Hello',
        'Message 2: How are you?',
        'Message 3: This is a test',
        'Message 4: of client',
        'Message 5: streaming',
      ];
      print('CLIENT: sending ${messages.length} messages');
      final messageStream = Stream.fromIterable(messages.map((m) => m.rpc))
          .asyncMap((message) async {
            print('CLIENT: -> "${message.value}"');
            // A small gap between messages.
            await Future<void>.delayed(Duration(milliseconds: 50));
            return message;
          });
      final result1 = await client.aggregateMessages(
        messageStream,
        context: context1,
      );
      print('CLIENT: aggregate: "${result1.value}"');
      // 2: aggregating with authentication.
      print('\n--- 2: aggregating with authentication ---');
      final authContext = RpcContextUtils.withBearerToken('aggregate-token-456')
          .withAdditionalHeaders({
            'client-version': '1.4.0',
            'aggregation-format': 'structured',
          })
          .withTraceId('auth-aggregate-456');
      final secureMessages = [
        'admin:status',
        'admin:reports',
        'admin:analytics',
        'admin:summary',
      ];
      final secureStream = Stream.fromIterable(secureMessages.map((m) => m.rpc))
          .asyncMap((message) async {
            print('CLIENT: -> authenticated message: "${message.value}"');
            await Future<void>.delayed(Duration(milliseconds: 30));
            return message;
          });
      final result2 = await client.aggregateMessages(
        secureStream,
        context: authContext,
      );
      print('CLIENT: authenticated aggregate: "${result2.value}"');
      // 3: aggregating, then cancelling.
      print('\n--- 3: cancelling an aggregation ---');
      final cancellationToken = RpcCancellationToken();
      final cancelContext = RpcContext.withCancellation(
        cancellationToken,
      ).withValue('batch-size', 100).withTraceId('cancel-aggregate-789');
      // Cancel after 150ms.
      Future<void>.delayed(Duration(milliseconds: 150), () {
        print('CLIENT: cancelling the aggregation');
        cancellationToken.cancel('User cancelled operation');
      });
      final longMessages = Stream.periodic(
        Duration(milliseconds: 50),
        (i) => 'Batch item #$i'.rpc,
      ).take(10);
      try {
        final result3 = await client.aggregateMessages(
          longMessages,
          context: cancelContext,
        );
        print('CLIENT: cancelled aggregate: "${result3.value}"');
      } catch (e) {
        print('CLIENT: the aggregation was cancelled: $e');
      }
      // 4: aggregating files.
      print('\n--- 4: aggregating files ---');
      final fileContext = RpcContext.withHeaders({
        'operation': 'file-processing',
        'format': 'batch',
      }).withTimeout(Duration(seconds: 5)).withTraceId('file-aggregate-012');
      final fileMessages = [
        'file:document1.pdf',
        'file:image2.jpg',
        'file:data3.json',
        'file:report4.xlsx',
      ];
      final fileStream = Stream.fromIterable(fileMessages.map((f) => f.rpc));
      final result4 = await client.aggregateMessages(
        fileStream,
        context: fileContext,
      );
      print('CLIENT: file result: "${result4.value}"');
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
abstract interface class IDataAggregatorContract implements IRpcContract {
  Future<RpcString> aggregateMessages(Stream<RpcString> messages);
}

final class DataAggregatorResponder extends RpcResponderContract
    implements IDataAggregatorContract {
  DataAggregatorResponder() : super('DataAggregatorService');
  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'AggregateMessages',
      handler: aggregateMessages,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Aggregates a stream of messages into a summary',
    );
  }

  @override
  Future<RpcString> aggregateMessages(
    Stream<RpcString> messages, {
    RpcContext? context,
  }) async {
    final logger = LogScope.noop;
    logger.info('starting the aggregation');
    logger.info('context: $context');
    final aggregationType = context?.getValue<String>('aggregation-type');
    final batchSize = context?.getValue<int>('batch-size');
    final format = context?.getHeader('aggregation-format');
    final operation = context?.getHeader('operation');
    final authToken = context?.getHeader('authorization');
    logger.info('type: $aggregationType, batch: $batchSize, format: $format');
    final receivedMessages = <String>[];
    int count = 0;
    try {
      await for (final message in messages) {
        context?.cancellationToken?.throwIfCancelled();
        count++;
        receivedMessages.add(message.value);
        logger.internal('message #$count: "${message.value}"');
        // Stand in for real work.
        await Future<void>.delayed(Duration(milliseconds: 10));
        // Stop at the batch limit, if one was given.
        if (batchSize != null && count >= batchSize) {
          logger.info('batch limit reached: $batchSize');
          break;
        }
      }
      logger.info('aggregation finished, $count messages');
      // What the summary looks like depends on the context.
      final String result;
      if (operation == 'file-processing') {
        result = _aggregateFiles(receivedMessages);
      } else if (authToken != null && authToken.startsWith('Bearer ')) {
        result = _aggregateSecureMessages(receivedMessages, format);
      } else {
        result = _aggregateRegularMessages(receivedMessages, aggregationType);
      }
      logger.internal('result: "$result"');
      return result.rpc;
    } catch (e) {
      logger.warning('the aggregation was cancelled: $e');
      final partialResult =
          'Partial aggregate: $count of ${receivedMessages.length} messages';
      return partialResult.rpc;
    }
  }

  String _aggregateRegularMessages(List<String> messages, String? type) {
    final totalChars = messages.fold<int>(0, (sum, msg) => sum + msg.length);
    return 'Aggregated ${messages.length} messages ($totalChars characters)';
  }

  String _aggregateSecureMessages(List<String> messages, String? format) {
    final adminCommands = messages.where((m) => m.startsWith('admin:')).length;
    if (format == 'structured') {
      return 'Secure Report: {total: ${messages.length}, admin_commands: $adminCommands, timestamp: ${DateTime.now()}}';
    }
    return 'Handled ${messages.length} authenticated messages '
        '($adminCommands admin commands)';
  }

  String _aggregateFiles(List<String> messages) {
    final files = messages.where((m) => m.startsWith('file:')).length;
    final totalSize = messages.length * 1024; // A stand-in for the real size.
    return 'Files handled: $files, total size: $totalSize KB';
  }
}

//
// THE CLIENT CONTRACT
//
final class DataAggregatorCaller extends RpcCallerContract
    implements IDataAggregatorContract {
  DataAggregatorCaller(RpcCallerEndpoint endpoint)
    : super('DataAggregatorService', endpoint);
  @override
  Future<RpcString> aggregateMessages(
    Stream<RpcString> messages, {
    RpcContext? context,
  }) {
    return callClientStream<RpcString, RpcString>(
      methodName: 'AggregateMessages',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: messages,
      context: context,
    );
  }
}
