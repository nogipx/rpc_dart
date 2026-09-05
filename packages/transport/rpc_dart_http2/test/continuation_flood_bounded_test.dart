// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The HTTP/2 CONTINUATION flood.
//
// package:http2 concatenates a HEADERS frame and the CONTINUATION frames that
// follow it into one buffer with no bound, rebuilding it on every CONTINUATION
// (O(N^2) memcpy). The block is not handed upward until END_HEADERS, so a peer
// that opens a header block and never ends it is below every rpc_dart limit --
// no stream is created, no handler dispatched -- and floods the server's single
// event loop.
//
// Measured against RpcHttp2Server before the guard, one connection:
//
//   64 MiB in 4096 CONTINUATION frames -> +53.7 MiB RSS, and an ordinary call
//   on ANOTHER connection TIMED OUT while the flood ran.
//
// After the guard: the flood connection is reset once its header block passes
// the policy's maxMetadataBytes, RSS growth is a fraction of a MiB, and the
// concurrent call is answered.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

const _preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';

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

Future<String> _callEcho(int port) async {
  try {
    final t = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: port,
    ).timeout(const Duration(seconds: 6));
    final caller = RpcCallerEndpoint(transport: t);
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 6));
    await caller.close().catchError((Object _) {});
    await t.close().catchError((Object _) {});
    return r.value;
  } catch (e) {
    return 'FAILED ${e.runtimeType}';
  }
}

void main() {
  late RpcHttp2Server server;

  tearDown(() => server.stop().catchError((Object _) {}));

  test(
    'a CONTINUATION flood is bounded and does not starve other clients',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        // A small cap keeps the test fast: the flood is refused after a few
        // frames instead of after tens of thousands.
        securityPolicy: const RpcSecurityPolicy(maxMetadataBytes: 64 * 1024),
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      expect(await _callEcho(server.port), 'echo-ok', reason: 'baseline');

      // Open a header block and never end it: HEADERS without END_HEADERS, then
      // CONTINUATION frames forever.
      final socket = await Socket.connect('127.0.0.1', server.port);
      final resetSeen = Completer<void>();
      socket.listen(
        (_) {},
        onError: (Object _) {
          if (!resetSeen.isCompleted) resetSeen.complete();
        },
        onDone: () {
          if (!resetSeen.isCompleted) resetSeen.complete();
        },
        cancelOnError: false,
      );
      socket.done.catchError((Object _) => socket);

      socket.add(_preface.codeUnits);
      socket.add(_frameHeader(length: 0, type: 0x4, flags: 0, streamId: 0));
      socket.add(_frameHeader(length: 0, type: 0x1, flags: 0, streamId: 1));

      const payloadBytes = 16384;
      final payload = Uint8List(payloadBytes);
      final contHeader = _frameHeader(
        length: payloadBytes,
        type: 0x9,
        flags: 0,
        streamId: 1,
      );

      // The load-bearing witness: the guard must RESET the flood connection.
      // Once the server destroys its socket, a subsequent client write fails.
      // Without the guard every one of these 4096 frames (64 MiB) is buffered
      // by package:http2 and accepted, so no write ever throws -- which is
      // exactly what the canary confirms when the cap is lifted.
      var floodReset = false;
      var framesSent = 0;
      final flooding = () async {
        try {
          for (var i = 0; i < 4096; i++) {
            socket.add(contHeader);
            socket.add(payload);
            framesSent = i + 1;
            if (i % 64 == 0) await socket.flush();
          }
          await socket.flush();
        } catch (_) {
          floodReset = true;
        }
      }();

      // While the flood is in flight, an ordinary client must still be served.
      // (In-process this is not a hard discriminator -- the flush() yields above
      // let the loop breathe -- but it must never regress to a hang.)
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        await _callEcho(server.port),
        'echo-ok',
        reason: 'the server must keep serving other clients during a flood',
      );

      await flooding.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          socket.destroy();
        },
      );
      socket.destroy();

      expect(
        floodReset,
        isTrue,
        reason:
            'the guard must reset the connection once its header block passes '
            'the cap; instead all $framesSent frames (up to 64 MiB) were '
            'accepted and buffered',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary request with real metadata is unaffected',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
      );
      await server.start();

      final t = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: t);
      // A fat-but-legal header value: a few KiB of metadata, well under the
      // 64 KiB header-block cap, so the guard must let the header block through
      // untouched. Sent as a real HTTP/2 header via the request context.
      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withHeaders({'x-tag': 'v' * 4096}),
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');

      await caller.close().catchError((Object _) {});
      await t.close().catchError((Object _) {});
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
