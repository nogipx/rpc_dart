// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

void main() {
  group('RpcTurnRelay transports', () {
    late TurnRelayServer server;

    setUp(() async {
      server = TurnRelayServer(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('exchange metadata and payload between caller and responder', () async {
      final callerClient = await TurnRelayClient.connect(
        serverAddress: server.bindAddress,
        serverPort: server.port,
      );
      addTearDown(callerClient.close);

      final responderClient = await TurnRelayClient.connect(
        serverAddress: server.bindAddress,
        serverPort: server.port,
      );
      addTearDown(responderClient.close);

      final callerTransport = RpcTurnRelayCallerTransport.fromClient(
        client: callerClient,
        peerAddress: responderClient.relayAddress,
        peerPort: responderClient.relayPort,
      );
      addTearDown(callerTransport.close);

      final responderTransport = RpcTurnRelayResponderTransport.fromClient(
        client: responderClient,
        peerAddress: callerClient.relayAddress,
        peerPort: callerClient.relayPort,
      );
      addTearDown(responderTransport.close);

      final requestCompleter = Completer<void>();
      final responderSub = responderTransport.incomingMessages.listen(
        (message) async {
          if (message.metadata != null && !requestCompleter.isCompleted) {
            await responderTransport.sendMetadata(
              message.streamId,
              RpcMetadata.forServerInitialResponse(),
            );
            return;
          }

          if (message.payload != null && !requestCompleter.isCompleted) {
            expect(utf8.decode(message.payload!), 'ping');
            await responderTransport.sendMessage(
              message.streamId,
              Uint8List.fromList('pong'.codeUnits),
              endStream: true,
            );
            requestCompleter.complete();
          }
        },
      );
      addTearDown(responderSub.cancel);

      final streamId = callerTransport.createStream();
      await callerTransport.sendMetadata(
        streamId,
        RpcMetadata.forClientRequestWithPath('/test/Echo'),
      );

      await callerTransport.sendMessage(
        streamId,
        Uint8List.fromList('ping'.codeUnits),
        endStream: true,
      );

      await requestCompleter.future.timeout(const Duration(seconds: 2));

      final responses = await callerTransport.incomingMessages
          .where((message) => message.streamId == streamId)
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 2));

      expect(responses, hasLength(2));
      final responseMetadata = responses.first;
      expect(responseMetadata.metadata?.getHeaderValue(':status'), '200');

      final responseData = responses.last;
      expect(responseData.payload, Uint8List.fromList('pong'.codeUnits));
      expect(responseData.isEndOfStream, isTrue);
    });
  });
}
