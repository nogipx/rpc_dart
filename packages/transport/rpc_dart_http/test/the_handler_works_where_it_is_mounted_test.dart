// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcHttpResponderTransport`'s doc says three times that its handler "mounts on any
// shelf server or router". It routed on `request.requestedUri.path` — the WHOLE path
// — so under a `/rpc/` mount every call arrived as `/rpc/Echo/echo` and was refused
// INVALID_ARGUMENT. The documented composition did not work.
//
// The mount is built with shelf's own primitive rather than by adding
// `shelf_router`: `Request.change(path: 'rpc')` is exactly what a mount does, moving
// a prefix out of `url` and into `handlerPath`. Same mechanism, no new dependency.
//
// The control is the unmounted rig, where `url` and `requestedUri.path` agree — which
// is why nothing noticed, and why the control has to be there: a fix that broke the
// ordinary case would otherwise pass.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}

typedef _Run = ({String outcome, String? sawPath});

Future<_Run> _call({required String? mountAt}) async {
  final transport = RpcHttpResponderTransport();
  String? sawPath;
  final responder = RpcResponderEndpoint(transport: transport);
  responder.registerServiceContract(_Echo()..setup());
  responder.start();
  transport.incomingMessages.listen(
    (m) => sawPath ??= m.methodPath,
    onError: (Object _) {},
  );

  Handler handler = transport.handler;
  if (mountAt != null) {
    final inner = handler;
    handler = (Request req) => inner(req.change(path: mountAt));
  }
  final http = await shelf_io.serve(handler, '127.0.0.1', 0);

  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl:
          'http://127.0.0.1:${http.port}${mountAt == null ? '' : '/$mountAt'}',
    ),
  );
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await responder.close().catchError((Object _) {});
    await http.close(force: true);
  });

  String outcome;
  try {
    final reply = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'echo',
          request: 'hi'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    outcome = 'ok: ${reply.value}';
  } on RpcStatusException catch (e) {
    outcome = 'status ${e.statusCode}: ${e.message}';
  } on TimeoutException {
    outcome = 'HUNG';
  }

  return (outcome: outcome, sawPath: sawPath);
}

void main() {
  test(
    'WITNESS: a handler mounted under a prefix still routes',
    () async {
      final run = await _call(mountAt: 'rpc');

      expect(
        run.sawPath,
        '/Echo/echo',
        reason:
            'the transport routed on the WHOLE request path, so a mount turns '
            'every method into one it has never heard of',
      );
      expect(run.outcome, 'ok: echo:hi');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: unmounted, where `url` and `requestedUri.path` agree. That agreement is
  // why the defect went unnoticed, and it is what a fix could break instead.
  test(
    'CONTROL: an unmounted handler is unchanged',
    () async {
      final run = await _call(mountAt: null);

      expect(run.sawPath, '/Echo/echo');
      expect(run.outcome, 'ok: echo:hi');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: a deeper mount, because one prefix level could be stripped by accident
  // — by a `split('/')` that happens to drop the right number of segments.
  test(
    'CONTROL: two prefix levels work too',
    () async {
      final run = await _call(mountAt: 'api/v1');

      expect(run.sawPath, '/Echo/echo');
      expect(run.outcome, 'ok: echo:hi');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
