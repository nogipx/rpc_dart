// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  // Server-push / server-initiated streams are NOT supported on the HTTP/2
  // responder. A send targeting a createStream()-minted (server-initiated) id
  // must fail loudly instead of silently dropping data. Legit responses, which
  // reply on the client-initiated stream id, must keep working.
  group('HTTP/2 responder: server-initiated streams', () {
    late ServerSocket serverSocket;
    late RpcHttp2ResponderTransport responder;
    late http2.ClientTransportConnection clientConnection;
    late Socket clientSocket;

    setUp(() async {
      serverSocket = await ServerSocket.bind('127.0.0.1', 0);

      final serverConnectionFuture = serverSocket.first.then((socket) {
        return http2.ServerTransportConnection.viaSocket(socket);
      });

      clientSocket = await Socket.connect('127.0.0.1', serverSocket.port);
      clientConnection = http2.ClientTransportConnection.viaSocket(
        clientSocket,
      );

      final serverConnection = await serverConnectionFuture;
      responder = RpcHttp2ResponderTransport(connection: serverConnection);
    });

    tearDown(() async {
      await responder.close();
      try {
        await clientConnection.finish();
      } catch (_) {}
      try {
        await clientSocket.close();
      } catch (_) {}
      await serverSocket.close();
    });

    test('sendMessage_on_server_initiated_id_throws', () async {
      // createStream() mints a server-initiated (even) id that is NOT a real
      // http2 stream. Sending on it must throw, not silently no-op.
      final serverStreamId = responder.createStream();

      final frame = ensureGrpcFrame(Uint8List.fromList([1, 2, 3]));
      expect(
        () => responder.sendMessage(serverStreamId, frame),
        throwsA(isA<StateError>()),
      );
    });

    test('sendMetadata_on_server_initiated_id_throws', () async {
      final serverStreamId = responder.createStream();
      expect(
        () => responder.sendMetadata(
          serverStreamId,
          RpcMetadata.forServerInitialResponse(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('sendMessage_on_unknown_id_throws', () async {
      // An id that was never created at all must also fail loudly.
      final frame = ensureGrpcFrame(Uint8List.fromList([9]));
      expect(
        () => responder.sendMessage(99999, frame),
        throwsA(isA<StateError>()),
      );
    });

    test('legit_unary_response_on_client_stream_id_round_trips', () async {
      // The client opens a stream; the responder replies on THAT (client)
      // stream id, which is a known incoming stream, so sends must succeed.
      final responseReceived = Completer<List<int>>();
      final responseBytes = <int>[];

      responder.incomingMessages.listen((msg) async {
        if (msg.isEndOfStream && msg.payload == null && msg.metadata == null) {
          // Client finished sending its request; reply on the same id.
          await responder.sendMetadata(
            msg.streamId,
            RpcMetadata.forServerInitialResponse(),
          );
          await responder.sendMessage(
            msg.streamId,
            ensureGrpcFrame(Uint8List.fromList([42])),
          );
          await responder.sendMetadata(
            msg.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
        }
      });

      final clientStream = clientConnection.makeRequest([
        http2.Header.ascii(':method', 'POST'),
        http2.Header.ascii(':path', '/Svc/Method'),
        http2.Header.ascii(':scheme', 'http'),
        http2.Header.ascii(':authority', '127.0.0.1'),
        http2.Header.ascii('content-type', 'application/grpc'),
        http2.Header.ascii('te', 'trailers'),
      ]);
      clientStream.sendData(
        ensureGrpcFrame(Uint8List.fromList([1])),
        endStream: true,
      );

      clientStream.incomingMessages.listen(
        (message) {
          if (message is http2.DataStreamMessage) {
            responseBytes.addAll(message.bytes);
          }
        },
        onDone: () {
          if (!responseReceived.isCompleted) {
            responseReceived.complete(responseBytes);
          }
        },
      );

      final received = await responseReceived.future.timeout(
        const Duration(seconds: 5),
      );
      // Body carries the single gRPC-framed response byte (42).
      final header = RpcMessageFrame.parseHeader(Uint8List.fromList(received));
      expect(header.messageLength, 1);
      expect(received.last, 42);
    });
  });
}
