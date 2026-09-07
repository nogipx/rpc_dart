// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call used to mint TWO context tokens -- one for its request id, one for its
// trace id -- and a token is three `Random.secure()` draws at ~34us. Measured
// over an in-memory pair, medians of five runs each:
//
//     tokens per unary call : 2.0  ->  1.0
//     unary p50, in-memory  : 227 us -> 197 us   (-13%)
//
// A call that starts its own trace contains exactly one request, so the two ids
// name the same thing; both are now derived from one token. Nothing is traded:
// same entropy, same generator, still unique, still unpredictable, and the two
// ids already travelled together in the same request metadata, so their being
// correlated reveals nothing new.
//
// What must stay true is pinned below: one token per call, ids still unique
// ACROSS calls, the two prefixes still distinct, and an explicitly supplied
// trace id still honoured.

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// The process-wide monotonic counter in a token's last 4 bytes.
///
/// Reading it from a throwaway context before and after a call counts exactly
/// how many tokens the call minted, with no instrumentation of the library.
int _counterOf(String id) {
  final body = id.substring(id.indexOf('_') + 1);
  final bytes = base64Url.decode('$body==');
  return (bytes[12] << 24) | (bytes[13] << 16) | (bytes[14] << 8) | bytes[15];
}

int _counterNow() => _counterOf(RpcContext.empty().requestId);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  /// What the peer actually put on the wire, as the handler sees it.
  final seen = <({String? requestId, String? traceId})>[];

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async {
        seen.add((
          requestId: context?.getHeader(RpcHeaders.xRequestId),
          traceId: context?.getHeader(RpcHeaders.xTraceId),
        ));
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
  _Svc svc,
});

_Rig _build() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  final svc = _Svc();
  responder.registerServiceContract(svc);
  responder.start();
  return (caller: caller, responder: responder, svc: svc);
}

Future<void> _call(RpcCallerEndpoint caller, {RpcContext? context}) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: context,
    )
    .then((_) {});

void main() {
  test('WITNESS: a call with no context mints exactly one token', () async {
    final rig = _build();
    await _call(rig.caller); // warm up: first call touches lazily-built state

    // The two throwaway contexts account for themselves, hence the -1.
    final before = _counterNow();
    const calls = 50;
    for (var i = 0; i < calls; i++) {
      await _call(rig.caller);
    }
    final after = _counterNow();

    expect(
      (after - before - 1) / calls,
      1.0,
      reason: 'the request id and the trace id must come from ONE token',
    );

    await rig.caller.close();
    await rig.responder.close();
  });

  test('WITNESS: a supplied context mints no token for its trace id', () async {
    // The other half of the change. A context built by the application already
    // paid for a request id; the trace id is now derived from it instead of
    // costing a second draw.
    final rig = _build();
    await _call(rig.caller, context: RpcContext.empty());

    final before = _counterNow();
    const calls = 50;
    for (var i = 0; i < calls; i++) {
      // One token for the context itself, and that must be all.
      await _call(rig.caller, context: RpcContext.empty());
    }
    final after = _counterNow();

    expect((after - before - 1) / calls, 1.0);

    await rig.caller.close();
    await rig.responder.close();
  });

  group('GUARD: the ids keep every property they had', () {
    test('distinct across calls, on the wire', () async {
      // Load-bearing: sharing a token WITHIN a call must not become sharing it
      // BETWEEN calls, which is what a prefix cached in the wrong place would
      // produce -- and every call would then look like the same one in logs.
      final rig = _build();
      for (var i = 0; i < 30; i++) {
        await _call(rig.caller);
      }

      expect(rig.svc.seen, hasLength(30));
      expect(rig.svc.seen.map((s) => s.requestId).toSet(), hasLength(30));
      expect(rig.svc.seen.map((s) => s.traceId).toSet(), hasLength(30));

      await rig.caller.close();
      await rig.responder.close();
    });

    test('a request id is never equal to a trace id', () async {
      final rig = _build();
      for (var i = 0; i < 10; i++) {
        await _call(rig.caller);
      }

      final wellFormed = RegExp(r'^(req|trace)_[A-Za-z0-9_-]{22}$');
      for (final s in rig.svc.seen) {
        expect(s.requestId, isNotNull);
        expect(s.traceId, isNotNull);
        expect(s.requestId, isNot(s.traceId));
        expect(s.requestId, matches(wellFormed));
        expect(s.traceId, matches(wellFormed));
      }

      await rig.caller.close();
      await rig.responder.close();
    });

    test('an explicitly supplied trace id still wins', () async {
      final rig = _build();
      await _call(
        rig.caller,
        context: RpcContext.withTraceId('trace_supplied-by-the-app'),
      );

      expect(rig.svc.seen.single.traceId, 'trace_supplied-by-the-app');

      await rig.caller.close();
      await rig.responder.close();
    });

    test('traceIdFor falls back when the request id is not ours', () async {
      // RpcContext.withHeaders lets an application pass any string as the
      // request id, so the derivation must not blindly slice a prefix off it.
      final derived = RpcContextUtils.traceIdFor('anything-at-all');
      expect(derived, matches(RegExp(r'^trace_[A-Za-z0-9_-]{22}$')));

      expect(RpcContextUtils.traceIdFor('req_ABC'), 'trace_ABC');
    });
  });
}
