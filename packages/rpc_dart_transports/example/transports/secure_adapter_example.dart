// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

Future<void> main() async {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.internal);

  final callerKeys = await Licensify.generateSigningKeys();
  final responderKeys = await Licensify.generateSigningKeys();
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final caller = SecureTransportAdapter.wrap(
    callerTransport,
    keyStore: SecureTransportKeyStore(
      transportId: 'demo-caller',
      keyPair: callerKeys,
      peerPublicKey: responderKeys.publicKey,
    ),
    logger: RpcLogger('SecureDemoCaller'),
  );

  final responder = SecureTransportAdapter.wrap(
    responderTransport,
    keyStore: SecureTransportKeyStore(
      transportId: 'demo-responder',
      keyPair: responderKeys,
      peerPublicKey: callerKeys.publicKey,
    ),
    logger: RpcLogger('SecureDemoResponder'),
  );

  await Future.wait([caller.ready, responder.ready]);
  print('🔐 Secure channel established between caller and responder');

  final responderSubscription = responder.incomingMessages.listen((message) {
    if (message.metadata != null) {
      print('➡️  Responder received metadata: ${message.metadata!.headers}');
      unawaited(responder.sendMetadata(
        message.streamId,
        RpcMetadata.forServerInitialResponse(),
      ));
      return;
    }

    if (message.payload != null) {
      final text = utf8.decode(message.payload!);
      print('➡️  Responder received payload: $text');
      final reply = utf8.encode('Reply for "$text"');
      unawaited(responder.sendMessage(
        message.streamId,
        Uint8List.fromList(reply),
      ));
      unawaited(responder.finishSending(message.streamId));
    }
  });

  final callerSubscription = caller.incomingMessages.listen((message) {
    if (message.metadata != null) {
      print('⬅️  Caller received metadata: ${message.metadata!.headers}');
      return;
    }

    if (message.payload != null) {
      final text = utf8.decode(message.payload!);
      print('⬅️  Caller received encrypted reply: $text');
    }

    if (message.isEndOfStream) {
      print('⬅️  Caller stream ${message.streamId} completed');
    }
  });

  final streamId = caller.createStream();
  await caller.sendMetadata(
    streamId,
    RpcMetadata.forClientRequestWithPath('/demo.SecureService/SayHello'),
  );

  await caller.sendMessage(
    streamId,
    Uint8List.fromList(utf8.encode('Hello secure world!')),
  );

  await caller.finishSending(streamId);

  await Future.delayed(const Duration(milliseconds: 300));

  await responderSubscription.cancel();
  await callerSubscription.cancel();
  await caller.close();
  await responder.close();
  await responderTransport.close();
  await callerTransport.close();
  callerKeys.privateKey.dispose();
  callerKeys.publicKey.dispose();
  responderKeys.privateKey.dispose();
  responderKeys.publicKey.dispose();

  print('✅ Demo finished, secure transport adapter cleaned up');
}
