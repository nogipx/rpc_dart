// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// This transport implements no IRpcStreamReset, so core's cancellation falls
// back to `sendMetadata(endStream: true)` with NO methodPath -- and
// `sendMetadata` treated every frame as a call-opening one, defaulting the path
// to `/Unknown/Unknown` and firing it.
//
// Measured, one unary call cancelled at 100 ms:
//
//   cancel      requests 2  [/Svc/slow, /Unknown/Unknown]
//   no cancel   requests 1  [/Svc/slow]
//
// The window BEFORE the request fires is worse, because the replacement takes
// the real call with it:
//
//   pre-fire cancel   requests [/Unknown/Unknown]  body 0 bytes
//   no cancel         requests [/Svc/slow]         body 16 bytes
//
// One request IS the call on this wire format, so a frame that names no method
// has nothing to send. Cancelling still does not STOP the server's handler --
// that needs a real abort (B-140) -- it just no longer costs a second request
// the server logs as an unregistered method, and a failing CORS preflight in a
// browser.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return 'slow:${req.value}'.rpc;
      },
    );
  }
}

typedef _Rig = ({List<String> paths, int port});

/// Serves the real responder, recording every path that reaches it.
Future<_Rig> _serve() async {
  final paths = <String>[];
  final responder = RpcHttpResponderTransport();
  final endpoint = RpcResponderEndpoint(transport: responder)
    ..registerServiceContract(_Svc()..setup())
    ..start();
  final server = await shelf_io.serve(
    (shelf.Request req) {
      paths.add('/${req.url.path}');
      return responder.handler(req);
    },
    '127.0.0.1',
    0,
  );
  addTearDown(() async {
    await endpoint.close();
    await server.close(force: true);
  });
  return (paths: paths, port: server.port);
}

void main() {
  test(
    'WITNESS: cancelling costs no second request',
    () async {
      final rig = await _serve();
      final caller = RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${rig.port}',
        ),
      );
      addTearDown(caller.close);

      final token = RpcCancellationToken();
      final call = caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'slow',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withCancellation(token),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel('user asked');
      await expectLater(call, throwsA(isA<RpcCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(
        rig.paths,
        ['/Svc/slow'],
        reason: 'the cancellation notice was fired as a call of its own',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'CONTROL: an uncancelled call is also one request',
    () async {
      final rig = await _serve();
      final caller = RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${rig.port}',
        ),
      );
      addTearDown(caller.close);

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'slow',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(reply.value, 'slow:x');
      expect(rig.paths, ['/Svc/slow']);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // The window before the request fires. Driven on the transport, because core
  // releases the stream too quickly for an endpoint-level test to reach it --
  // and this is the arm where the damage is loss rather than noise.
  test(
    'WITNESS: a pre-fire cancellation notice does not replace the call',
    () async {
      final bodies = <int>[];
      final paths = <String>[];
      final server = await shelf_io.serve(
        (shelf.Request req) async {
          paths.add('/${req.url.path}');
          bodies.add((await req.read().expand((c) => c).toList()).length);
          return shelf.Response.ok(null);
        },
        '127.0.0.1',
        0,
      );
      addTearDown(() => server.close(force: true));

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(transport.close);

      final id = transport.createStream();
      await transport.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'slow'),
      );
      await transport.sendMessage(
        id,
        RpcMessageFrame.encode(_codec.serialize('payload'.rpc)),
      );
      // Exactly what core's _notifyPeerOfCancellation sends.
      await transport.sendMetadata(
        id,
        RpcMetadata([
          RpcHeader(RpcHeaders.xClientCancelled, 'true'),
          RpcHeader(RpcHeaders.xCancellationReason, 'user asked'),
          RpcHeader(RpcHeaders.grpcStatus, '${RpcStatus.cancelled}'),
        ]),
        endStream: true,
      );
      await transport.finishSending(id);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        paths,
        ['/Svc/slow'],
        reason: 'the notice replaced the pending call and fired in its place',
      );
      expect(bodies, [
        16,
      ], reason: 'and took the buffered request body with it');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // GUARD: a metadata frame that DOES name a method still opens a call. The
  // witness would also pass on a transport that had stopped sending anything.
  test(
    'GUARD: an opening frame still fires its request',
    () async {
      final paths = <String>[];
      final server = await shelf_io.serve(
        (shelf.Request req) {
          paths.add('/${req.url.path}');
          return shelf.Response.ok(null);
        },
        '127.0.0.1',
        0,
      );
      addTearDown(() => server.close(force: true));

      final transport = RpcHttpCallerTransport(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(transport.close);

      final id = transport.createStream();
      await transport.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'slow'),
        endStream: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(paths, ['/Svc/slow']);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
