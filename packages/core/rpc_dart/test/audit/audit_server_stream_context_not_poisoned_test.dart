// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: the caller-pipeline server-stream bridge fired
// `ctx.cancellationToken.cancel(...)` in its StreamController `onCancel`
// UNCONDITIONALLY. On NORMAL completion `onDone` runs first, then `await for`
// tears down its subscription, which triggers `onCancel` — so a stream that
// completed successfully still cancelled the context's token. When a single
// RpcContext is REUSED across calls (e.g. a blob download that fetches the
// manifest then its chunks with one context, calling throwIfCancelled between),
// the second call threw `RpcCancelledException` even though the first succeeded.
//
// CORRECT behavior: a server-stream that completes normally must NOT cancel its
// (possibly reused) context token. A real mid-stream cancellation still must.
//
// fvm dart test test/audit/audit_server_stream_context_not_poisoned_test.dart

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Req implements IRpcSerializable {
  _Req(this.value);
  final String value;
  factory _Req.fromJson(Map<String, dynamic> json) =>
      _Req(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

final class _Res implements IRpcSerializable {
  _Res(this.value);
  final String value;
  factory _Res.fromJson(Map<String, dynamic> json) =>
      _Res(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

final class _StreamService extends RpcResponderContract {
  static const serviceId = 'StreamService';

  /// Emits two responses then completes normally.
  static const finiteId = 'Finite';

  /// Emits one response then stays open forever (until the client cancels).
  static const openId = 'Open';

  _StreamService() : super(serviceId);

  @override
  void setup() {
    addServerStreamMethod<_Req, _Res>(
      methodName: finiteId,
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Res>(_Res.fromJson),
      handler: (request, {context}) async* {
        yield _Res('${request.value}:1');
        yield _Res('${request.value}:2');
      },
    );

    addServerStreamMethod<_Req, _Res>(
      methodName: openId,
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Res>(_Res.fromJson),
      handler: (request, {context}) {
        final controller = StreamController<_Res>();
        controller.add(_Res('${request.value}:1'));
        // Never closed — the stream stays open until the caller cancels.
        return controller.stream;
      },
    );
  }
}

void main() {
  group('caller-pipeline server-stream context poisoning', () {
    late RpcCallerEndpoint caller;
    late RpcResponderEndpoint responder;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      caller = RpcCallerEndpoint(transport: pair.$1);
      responder = RpcResponderEndpoint(transport: pair.$2)
        ..registerServiceContract(_StreamService())
        ..start();
    });

    tearDown(() async {
      await responder.close();
      await caller.close();
    });

    Stream<_Res> finite(_Req req, {RpcContext? context}) =>
        caller.serverStream<_Req, _Res>(
          serviceName: _StreamService.serviceId,
          methodName: _StreamService.finiteId,
          requestCodec: RpcCodec<_Req>(_Req.fromJson),
          responseCodec: RpcCodec<_Res>(_Res.fromJson),
          request: req,
          context: context,
        );

    test(
      'normal completion does NOT cancel the (reused) context token',
      () async {
        final token = RpcCancellationToken();
        final context = RpcContextBuilder()
            .withGeneratedTraceId()
            .withCancellation(token)
            .build();

        final first = await finite(
          _Req('a'),
          context: context,
        ).map((r) => r.value).toList();
        expect(first, equals(['a:1', 'a:2']));

        // The regression: a normally-completed stream must leave the token
        // untouched so the context can be reused.
        expect(
          token.isCancelled,
          isFalse,
          reason:
              'normal server-stream completion must not fire the context token',
        );

        // And the reused context must still work for a second call — this is
        // the blob manifest->chunks sequence that originally broke.
        final second = await finite(
          _Req('b'),
          context: context,
        ).map((r) => r.value).toList();
        expect(second, equals(['b:1', 'b:2']));
      },
    );

    test(
      'real mid-stream cancellation still fires the token and surfaces it',
      () async {
        final token = RpcCancellationToken();
        final context = RpcContextBuilder()
            .withGeneratedTraceId()
            .withCancellation(token)
            .build();

        final stream = caller.serverStream<_Req, _Res>(
          serviceName: _StreamService.serviceId,
          methodName: _StreamService.openId,
          requestCodec: RpcCodec<_Req>(_Req.fromJson),
          responseCodec: RpcCodec<_Res>(_Res.fromJson),
          request: _Req('x'),
          context: context,
        );

        Object? caught;
        try {
          await for (final _ in stream) {
            // Got the first item; now cancel mid-stream.
            token.cancel('test cancel');
          }
        } catch (e) {
          caught = e;
        }

        expect(caught, isA<RpcCancelledException>());
        expect(token.isCancelled, isTrue);
      },
    );
  });
}
