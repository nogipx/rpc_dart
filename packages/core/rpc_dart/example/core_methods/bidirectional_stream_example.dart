// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await BidirectionalStreamExample.run();
}

/// Bidirectional streaming, using contracts and [RpcContext].
class BidirectionalStreamExample {
  static Future<void> run() async {
    // logging configured via LogController
    print('\n=== Bidirectional streaming with contracts ===\n');
    // The transports.
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    // The server endpoint, with its contract registered.
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'Server',
    );
    final service = ChatServiceResponder();
    serverEndpoint.registerServiceContract(service);
    serverEndpoint.start();
    // The client endpoint.
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'Client',
    );
    final client = ChatServiceCaller(clientEndpoint);
    try {
      // 1: a plain chat.
      print('\n--- 1: a plain chat ---');
      final context1 = RpcContext.empty()
          .withTraceId('chat-trace-123')
          .withValue('user-id', 'user-456')
          .withValue('session-id', 'session-789');
      final messagesToSend = [
        'ping',
        'time',
        'random number',
        'hello, world!',
        'quit',
      ];
      final responses = <String>[];
      await client
          .chatWithServer(
            Stream.fromIterable(messagesToSend.map((m) => m.rpc)),
            context: context1,
          )
          .forEach((response) {
            responses.add(response.value);
            print('CLIENT: response: "${response.value}"');
          });
      print('CLIENT: ${responses.length} responses in total');
      // 2: a chat with authentication.
      print('\n--- 2: a chat with authentication ---');
      final authContext = RpcContextUtils.withBearerToken('secret-token-123')
          .withAdditionalHeaders({'user-role': 'admin'})
          .withTraceId('auth-chat-trace-456');
      final secureMessages = ['admin:status', 'admin:users', 'admin:logout'];
      await client
          .chatWithServer(
            Stream.fromIterable(secureMessages.map((m) => m.rpc)),
            context: authContext,
          )
          .forEach((response) {
            print('CLIENT: authenticated response: "${response.value}"');
          });
      // 3: a chat that gets cancelled.
      print('\n--- 3: cancelling a chat ---');
      final cancellationToken = RpcCancellationToken();
      final cancelContext = RpcContext.withCancellation(
        cancellationToken,
      ).withValue('chat-type', 'long-running');
      // Cancel after 300ms.
      Future<void>.delayed(Duration(milliseconds: 300), () {
        print('CLIENT: cancelling the chat');
        cancellationToken.cancel('User left chat');
      });
      final longMessages = Stream.periodic(
        Duration(milliseconds: 100),
        (i) => 'Message #$i'.rpc,
      ).take(10);
      try {
        await client
            .chatWithServer(longMessages, context: cancelContext)
            .forEach((response) {
              print('CLIENT: long response: "${response.value}"');
            });
      } catch (e) {
        print('CLIENT: the chat was cancelled: $e');
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
abstract interface class IChatServiceContract implements IRpcContract {
  Stream<RpcString> chatWithServer(Stream<RpcString> messages);
}

final class ChatServiceResponder extends RpcResponderContract
    implements IChatServiceContract {
  ChatServiceResponder() : super('ChatService');
  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'ChatWithServer',
      handler: chatWithServer,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'A bidirectional chat with the server',
    );
  }

  @override
  Stream<RpcString> chatWithServer(
    Stream<RpcString> messages, {
    RpcContext? context,
  }) async* {
    final logger = LogScope.noop;
    logger.info('starting a chat session');
    logger.info('context: $context');
    final userId = context?.getValue<String>('user-id');
    final sessionId = context?.getValue<String>('session-id');
    final userRole = context?.getHeader('user-role');
    final authToken = context?.getHeader('authorization');
    logger.info('user: $userId, session: $sessionId, role: $userRole');
    // Authentication, for the privileged commands.
    final isAuthenticated =
        authToken != null && authToken.startsWith('Bearer ');
    await for (final message in messages) {
      context?.cancellationToken?.throwIfCancelled();
      logger.info('message: "${message.value}"');
      final messageText = message.value;
      String response;
      // Route by message kind.
      if (messageText.startsWith('admin:')) {
        if (!isAuthenticated || userRole != 'admin') {
          response = 'Error: not permitted to run that command';
        } else {
          final command = messageText.substring(6);
          response = _handleAdminCommand(command);
        }
      } else {
        response = _handleRegularMessage(messageText);
      }
      logger.internal('response: "$response"');
      yield response.rpc;
      // Leave the chat when asked to.
      if (messageText == 'quit' || messageText == 'admin:logout') {
        logger.info('ending the chat session');
        break;
      }
      await Future<void>.delayed(Duration(milliseconds: 10));
    }
  }

  String _handleAdminCommand(String command) {
    switch (command) {
      case 'status':
        return 'System status: OK, 42 active users';
      case 'users':
        return 'Active users: Alice, Bob, Charlie';
      case 'logout':
        return 'Admin session ended';
      default:
        return 'Unknown admin command: $command';
    }
  }

  String _handleRegularMessage(String message) {
    switch (message) {
      case 'ping':
        return 'pong';
      case 'time':
        return 'Current time: ${DateTime.now()}';
      case 'random number':
        final random = (DateTime.now().millisecondsSinceEpoch % 100) + 1;
        return 'A random number between 1 and 100: $random';
      case 'quit':
        return 'Goodbye. The chat is over.';
      default:
        return 'Echo: $message';
    }
  }
}

//
// THE CLIENT CONTRACT
//
final class ChatServiceCaller extends RpcCallerContract
    implements IChatServiceContract {
  ChatServiceCaller(RpcCallerEndpoint endpoint)
    : super('ChatService', endpoint);
  @override
  Stream<RpcString> chatWithServer(
    Stream<RpcString> messages, {
    RpcContext? context,
  }) {
    return callBidirectionalStream<RpcString, RpcString>(
      methodName: 'ChatWithServer',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: messages,
      context: context,
    );
  }
}
