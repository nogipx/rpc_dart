// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A stream its consumer cancels is a call that ended: onCall sees it as
// cancelled, RpcCallSpy records it, and onError, which is for failures, does
// not hear of it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Ticks extends RpcResponderContract {
  _Ticks() : super('Ticks');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'endless',
      handler: (r, {RpcContext? context}) =>
          Stream.periodic(const Duration(milliseconds: 5), (_) => r),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _TicksModule extends RpcServerModule {
  @override
  String get name => 'Ticks';

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) => [_Ticks()];
}

void main() {
  test('a cancelled stream reaches onCall and the spy, not onError', () async {
    final ended = Completer<RpcCallEvent>();
    final errors = <Object>[];
    final spy = RpcCallSpy();
    final app = await RpcTestApp.start(
      modules: [_TicksModule()],
      interceptors: [spy],
      config: RpcAppConfig(
        onCall: (event) {
          if (!ended.isCompleted) ended.complete(event);
        },
        onError: (error, _, _, _) => errors.add(error),
      ),
    );
    addTearDown(app.dispose);

    await app.caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Ticks',
          methodName: 'endless',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .first;

    final event = await ended.future.timeout(const Duration(seconds: 5));
    expect(event.callType, RpcMethodType.serverStream);
    expect(event.outcome, isA<RpcCallCancelled>());
    expect(event.success, isFalse);
    expect(event.error, isNull);
    expect(errors, isEmpty);
    expect(
      spy.callsTo('Ticks', 'endless').single.outcome,
      isA<RpcCallCancelled>(),
    );
    expect(spy.errorCount, 0);
  });
}
