// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The two stream middleware helpers hand the source stream back unchanged when no
// middleware is configured, instead of wrapping it in an `async*` that forwards
// each message. These tests pin what that must not break.
//
// The bypass CHANGES A CONTRACT, which is the point of the last test: the
// middleware set is fixed when the stream is built, so one added mid-stream does
// not join it. That matches interceptors, whose chain is built once at call start.
//
// The measurement behind the change is in `.claude/loop/rounds/509` — no test here
// can witness a cost, and all four pass with the bypass ablated.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Tagging extends IRpcMiddleware {
  _Tagging(this.tag);

  final String tag;

  @override
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext context,
    TRequest request,
  ) => request;

  @override
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext context,
    TResponse response,
  ) {
    if (response is RpcString) {
      return '${response.value}+$tag'.rpc as TResponse;
    }
    return response;
  }
}

final class _Feed extends RpcResponderContract {
  _Feed() : super('Feed');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'tick',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        for (var i = 0; i < int.parse(req.value); i++) {
          yield 'm$i'.rpc;
        }
      },
    );
  }
}

({RpcCallerEndpoint caller, RpcResponderEndpoint responder}) _pair() {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Feed())
    ..start();
  return (caller: RpcCallerEndpoint(transport: client), responder: responder);
}

Future<List<String>> _drain(RpcCallerEndpoint caller, int n) async {
  final out = <String>[];
  await for (final m in caller.serverStream<RpcString, RpcString>(
    serviceName: 'Feed',
    methodName: 'tick',
    request: '$n'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  )) {
    out.add(m.value);
  }
  return out;
}

void main() {
  // No test here can witness the defect — it is a cost, and every one of these
  // passes with the bypass ablated. The witness is the bench. These exist so the
  // bypass cannot be bought by dropping middleware that should have run.
  group('GUARD: middleware still runs on streaming calls', () {
    test(
      'a response middleware is applied to every message',
      () async {
        final p = _pair();
        p.caller.addMiddleware(_Tagging('a'));
        addTearDown(() async {
          await p.caller.close();
          await p.responder.close();
        });

        expect(await _drain(p.caller, 4), ['m0+a', 'm1+a', 'm2+a', 'm3+a']);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'two middlewares are applied in reverse order on responses',
      () async {
        // Responses run backwards, so 'b' is applied before 'a'. An `isEmpty`
        // bypass that accidentally became an `always` bypass passes the previous
        // test if the tag happens to be absent; this one reads the ORDER.
        final p = _pair();
        p.caller
          ..addMiddleware(_Tagging('a'))
          ..addMiddleware(_Tagging('b'));
        addTearDown(() async {
          await p.caller.close();
          await p.responder.close();
        });

        expect(await _drain(p.caller, 2), ['m0+b+a', 'm1+b+a']);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'with NO middleware every message still arrives, in order',
      () async {
        final p = _pair();
        addTearDown(() async {
          await p.caller.close();
          await p.responder.close();
        });

        expect(await _drain(p.caller, 50), [
          for (var i = 0; i < 50; i++) 'm$i',
        ]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  test(
    'the middleware set is fixed when the stream is built',
    () async {
      // A BEHAVIOUR CHANGE, stated as a test rather than left to be discovered.
      // The helpers used to re-read `_middlewares` per message, so a middleware
      // added mid-stream applied to later messages. Bypassing the wrapper when the
      // list is empty means the decision is made once, at build time.
      //
      // This makes middleware agree with interceptors, whose chain is already built
      // once at call start — see `_invokeUnaryInterceptors` and its siblings, which
      // loop over `_interceptors` synchronously with no await in the body.
      final p = _pair();
      addTearDown(() async {
        await p.caller.close();
        await p.responder.close();
      });

      final out = <String>[];
      await for (final m in p.caller.serverStream<RpcString, RpcString>(
        serviceName: 'Feed',
        methodName: 'tick',
        request: '6'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )) {
        out.add(m.value);
        if (out.length == 2) p.caller.addMiddleware(_Tagging('late'));
      }

      expect(
        out.any((v) => v.contains('late')),
        isFalse,
        reason:
            'the stream was built with no middleware, so one added while it runs '
            'does not join it',
      );
      expect(out, [for (var i = 0; i < 6; i++) 'm$i']);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
