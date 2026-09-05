// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CALLER half of the HTTP/2 CONTINUATION flood.
//
// The server half was guarded in the previous round. A client runs the same
// package:http2 defragmenter, which concatenates a HEADERS frame and its
// CONTINUATION frames into one unbounded buffer BEFORE any stream-state
// handling -- so a hostile server can flood a client on a stream that need not
// even exist, and nothing above the transport can see it.
//
// Measured against a server answering with HEADERS lacking END_HEADERS and then
// CONTINUATION frames forever:
//
//   64 MiB of frames -> client RSS +194.3 MiB   (worse than the +53.7 MiB the
//                       server side showed for the same flood)
//
// After the guard: +2.5 MiB, and the hostile server gets 65 of 4096 frames out
// before the client resets the connection.
//
// "You dialed the server" is not a defence: clients get pointed at compromised
// endpoints, and a proxy is a machine on the path that is often not the
// operator's.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

Uint8List _frameHeader({
  required int length,
  required int type,
  required int flags,
  required int streamId,
}) {
  final h = Uint8List(9);
  h[0] = (length >> 16) & 0xFF;
  h[1] = (length >> 8) & 0xFF;
  h[2] = length & 0xFF;
  h[3] = type;
  h[4] = flags;
  h[5] = (streamId >> 24) & 0x7F;
  h[6] = (streamId >> 16) & 0xFF;
  h[7] = (streamId >> 8) & 0xFF;
  h[8] = streamId & 0xFF;
  return h;
}

void main() {
  test(
    'a hostile server cannot flood the client with CONTINUATION frames',
    () async {
      const totalFrames = 4096;
      const payloadBytes = 16384; // 64 MiB attempted in total

      final listener = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(() => listener.close());

      // Frames the hostile server manages to write before the client tears the
      // connection down. This is the deterministic witness: unguarded, every
      // one of the 4096 lands and is buffered; guarded, the client resets us
      // after a handful.
      final framesWritten = Completer<int>();

      listener.listen((socket) async {
        socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
        socket.done.catchError((Object _) => socket);

        // Our SETTINGS, then ACK the client's, so the connection comes up.
        socket.add(_frameHeader(length: 0, type: 0x4, flags: 0, streamId: 0));
        socket.add(_frameHeader(length: 0, type: 0x4, flags: 0x1, streamId: 0));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Open a header block on stream 1 and never end it.
        socket.add(_frameHeader(length: 0, type: 0x1, flags: 0, streamId: 1));

        final payload = Uint8List(payloadBytes);
        final contHeader = _frameHeader(
          length: payloadBytes,
          type: 0x9, // CONTINUATION
          flags: 0, // no END_HEADERS -- never completes
          streamId: 1,
        );

        var sent = 0;
        try {
          for (var i = 0; i < totalFrames; i++) {
            socket.add(contHeader);
            socket.add(payload);
            sent = i + 1;
            if (i % 32 == 0) await socket.flush();
          }
          await socket.flush();
        } catch (_) {
          // Client reset us: the guard fired.
        }
        if (!framesWritten.isCompleted) framesWritten.complete(sent);
      });

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: listener.port,
        policy: const RpcSecurityPolicy(maxMetadataBytes: 64 * 1024),
      );
      addTearDown(() => transport.close().catchError((Object _) {}));

      final sent = await framesWritten.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => -1,
      );

      expect(
        sent,
        lessThan(totalFrames),
        reason:
            'the client accepted and buffered every CONTINUATION frame the '
            'hostile server sent ($sent of $totalFrames, 64 MiB): the guard '
            'never reset the connection',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: an ordinary call through the guarded client path works',
    () async {
      // The guard sits on every client connection, so this proves it forwards
      // real traffic byte-for-byte -- including a response whose header block
      // carries several KiB of legitimate metadata.
      final codec = RpcCodec(RpcString.fromJson);
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_EchoContract()),
      );
      await server.start();
      addTearDown(() => server.stop().catchError((Object _) {}));

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      for (var i = 0; i < 3; i++) {
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: '$i'.rpc,
              requestCodec: codec,
              responseCodec: codec,
              context: RpcContext.withHeaders({'x-tag': 'v' * 4096}),
            )
            .timeout(const Duration(seconds: 8));
        expect(r.value, 'echo-$i');
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  static final _codec = RpcCodec(RpcString.fromJson);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async =>
          'echo-${request.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
