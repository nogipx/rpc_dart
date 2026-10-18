// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A caller's cancel reaches the handler's token under RpcHttpServer.
//
// HTTP/1.1 has no cancel frame: the caller aborts its request, which closes
// the connection. dart:io sees the close and neither it nor shelf tells the
// handler, so a handler with no deadline ran on.
//
// How long the close takes to arrive is the platform's: the bound here is
// generous on purpose, and the control is that a call left alone is never
// cancelled.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _bound = Duration(seconds: 5);

final class _Hanging extends RpcResponderContract {
  _Hanging(this.entered, this.cancelled) : super('Svc');

  final Completer<void> entered;
  final Completer<void> cancelled;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hang',
      handler: (request, {RpcContext? context}) async {
        if (!entered.isCompleted) entered.complete();
        final token = context?.cancellationToken;
        if (token != null) {
          await token.cancelled;
          if (!cancelled.isCompleted) cancelled.complete();
        } else {
          await Completer<void>().future;
        }
        throw RpcStatusException(RpcStatus.cancelled, 'cancelled');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<
  ({
    RpcCallerEndpoint caller,
    Completer<void> entered,
    Completer<void> cancelled,
  })
>
_serve({LogScope? logger}) async {
  final entered = Completer<void>();
  final cancelled = Completer<void>();
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    logger: logger,
    mode: RpcResponderMode(
      (e) => e.registerServiceContract(_Hanging(entered, cancelled)),
    ),
  );
  await server.start();
  await server.afterModulesStart();
  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.actualPort}',
    ),
  );
  addTearDown(() async {
    await caller.close();
    await server.stop();
  });
  return (caller: caller, entered: entered, cancelled: cancelled);
}

Future<void> _call(RpcCallerEndpoint caller, RpcContext context) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'hang',
      request: const RpcString('x'),
      requestCodec: _codec,
      responseCodec: _codec,
      context: context,
    )
    .then((_) {}, onError: (Object _) {});

void main() {
  test('WITNESS: a cancelled call cancels its handler', () async {
    final s = await _serve();
    final token = RpcCancellationToken();
    final call = _call(s.caller, RpcContext.empty().withCancellation(token));
    // Cancelled once the handler runs: cancelled earlier, under load, the
    // request never reached it and there was nothing to tell.
    await s.entered.future.timeout(_bound);
    token.cancel('the caller gave up');
    await call;

    await s.cancelled.future.timeout(
      _bound,
      onTimeout: () => fail(
        'the handler was not told within $_bound that its caller cancelled '
        '(handler entered: ${s.entered.isCompleted})',
      ),
    );
  });

  // A client leaving is routine and any peer can repeat it, so the release
  // that follows it is not a warning.
  test('GUARD: a cancel logs no warning on the server', () async {
    final controller = LogController(minLevel: RpcLogLevel.internal);
    final warnings = <String>[];
    controller.stream.listen((r) {
      if (r is LogEvent && r.level.index >= RpcLogLevel.warning.index) {
        warnings.add(r.message);
      }
    });
    final s = await _serve(logger: LogScope(controller, 'server'));
    final token = RpcCancellationToken();
    final call = _call(s.caller, RpcContext.empty().withCancellation(token));
    await s.entered.future.timeout(_bound);
    token.cancel('the caller gave up');
    await call;
    await s.cancelled.future.timeout(_bound);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(warnings, isEmpty);
  });

  test(
    'CONTROL: a call left alone is not cancelled',
    () async {
      final s = await _serve();
      unawaited(_call(s.caller, RpcContext.empty()));
      await Future<void>.delayed(_bound);
      expect(s.cancelled.isCompleted, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
