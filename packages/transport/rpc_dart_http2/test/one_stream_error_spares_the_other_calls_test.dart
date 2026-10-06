// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An error about one stream -- a malformed frame from the client, a reset from
// the server -- ends that call and no other. The endpoints answer every active
// call on a broadcast error, and RpcClientConnection retires the transport on
// one, so a stream-scoped error has to arrive marked as such.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _slow = Duration(milliseconds: 600);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Slow',
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(_slow);
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<String> _call(RpcCallerEndpoint caller, String method) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .then(
      (_) => 'ok',
      onError: (Object e) =>
          e is RpcStatusException ? 'status ${e.statusCode}' : '$e',
    );

void main() {
  test('a refused frame on one stream fails no other call', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    addTearDown(() async {
      await transport.close();
      await server.stop();
    });
    final caller = RpcCallerEndpoint(transport: transport);

    final innocent = [for (var i = 0; i < 3; i++) _call(caller, 'Slow')];
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final bad = transport.createStream();
    final badStatus = Completer<String?>();
    transport.getMessagesForStream(bad).listen((m) {
      final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      if (status != null && !badStatus.isCompleted) badStatus.complete(status);
    }, onError: (Object _) {});
    await transport.sendMetadata(
      bad,
      RpcMetadata.forClientRequest('Svc', 'Slow'),
    );
    // Over the server's message limit: refused by its frame parser.
    await transport.sendMessage(
      bad,
      RpcMessageFrame.encode(Uint8List(4096), compressed: false),
      endStream: true,
    );

    expect(
      await badStatus.future.timeout(const Duration(seconds: 5)),
      RpcStatus.resourceExhausted.toString(),
      reason: 'the refused stream itself is still answered',
    );
    expect(await Future.wait(innocent), ['ok', 'ok', 'ok']);
  });

  test('a server reset of one call does not retire the connection', () async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((client) {
      http2.ServerTransportConnection.viaSocket(client).incomingStreams.listen((
        stream,
      ) async {
        String? path;
        await for (final m in stream.incomingMessages) {
          if (m is http2.HeadersStreamMessage) {
            for (final h in m.headers) {
              if (String.fromCharCodes(h.name) == ':path') {
                path = String.fromCharCodes(h.value);
              }
            }
          }
          if (m.endStream) break;
        }
        if (path == '/Svc/Reset') {
          stream.terminate();
          return;
        }
        await Future<void>.delayed(_slow);
        try {
          stream.sendHeaders([
            http2.Header.ascii(':status', '200'),
            http2.Header.ascii('content-type', 'application/grpc'),
          ]);
          stream.sendData(
            RpcMessageFrame.encode(
              _codec.serialize('ok'.rpc),
              compressed: false,
            ),
          );
          stream.sendHeaders([
            http2.Header.ascii('grpc-status', '0'),
          ], endStream: true);
        } catch (_) {}
      }, onError: (Object _) {});
    }, onError: (Object _) {});

    final connection = RpcClientConnection(
      transportFactory: () =>
          RpcHttp2CallerTransport.connect(host: '127.0.0.1', port: socket.port),
    );
    addTearDown(() async {
      await connection.dispose();
      await socket.close();
    });
    connection.connect();
    await connection.state
        .firstWhere((s) => s is RpcClientOnline)
        .timeout(const Duration(seconds: 5));
    final caller = RpcCallerEndpoint(transport: connection.transport);

    final innocent = [for (var i = 0; i < 3; i++) _call(caller, 'Slow')];
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(await _call(caller, 'Reset'), isNot('ok'));
    expect(await Future.wait(innocent), ['ok', 'ok', 'ok']);
  });
}
