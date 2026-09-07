// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response bigger than the CLIENT's maxMessageLengthBytes used to take the
// whole WebSocket connection down. Found by running one battery on three
// transports -- a server sending 2 MiB to a client capped at 256 KiB:
//
//     websocket  RpcFrameException, and every later call got
//                "Transport is disconnected and has no socket"
//     http2      RpcException, connection fine
//     isolate    no limit applied at all on the unary path
//
// The unit coverage for the skip is in rpc_dart's
// test/transports/oversized_frame_is_per_call_test.dart; this is the end-to-end
// half, over a real socket, because that is where the divergence was found.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Everything except the message ceiling is generous, so a refusal names the
/// control under test rather than some neighbouring cap.
const _clientPolicy = RpcSecurityPolicy(
  maxMessageLengthBytes: 256 * 1024,
  maxMetadataBytes: 1 << 20,
  maxHeaders: 1024,
  maxHeaderValueBytes: 1 << 16,
  maxActiveStreams: 1024,
);

const _serverPolicy = RpcSecurityPolicy(
  maxMessageLengthBytes: 8 * 1024 * 1024,
  maxMetadataBytes: 1 << 20,
  maxHeaders: 1024,
  maxHeaderValueBytes: 1 << 16,
  maxActiveStreams: 1024,
);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'big',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async =>
          ('x' * (2 * 1024 * 1024)).rpc,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'small',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'bigStream',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        yield 'first'.rpc;
        yield ('x' * (2 * 1024 * 1024)).rpc;
        yield 'third'.rpc;
      },
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller});

Future<_Rig> _connect() async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http),
    policy: _serverPolicy,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();

  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
    policy: _clientPolicy,
  );
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await server.stop();
    await http.close(force: true);
  });
  return (caller: caller);
}

Future<RpcString> _unary(RpcCallerEndpoint caller, String method) =>
    caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'go'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

void main() {
  test(
    'an oversized response fails the call with RESOURCE_EXHAUSTED',
    () async {
      // WITNESS. Pre-fix: RpcFrameException "Incoming frame buffer overflow".
      final rig = await _connect();

      await expectLater(
        _unary(rig.caller, 'big').timeout(const Duration(seconds: 20)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.resourceExhausted,
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('the connection survives it', () async {
    // WITNESS, and the one that matters: pre-fix the next call reported
    // "Transport is disconnected and has no socket; call reconnect()".
    final rig = await _connect();

    await expectLater(
      _unary(rig.caller, 'big').timeout(const Duration(seconds: 20)),
      throwsA(isA<RpcStatusException>()),
    );

    final after = await _unary(
      rig.caller,
      'small',
    ).timeout(const Duration(seconds: 20));
    expect(after.value, 'ok');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'a stream keeps the items it already delivered',
    () async {
      // Pre-fix the connection died before even the first item arrived.
      final rig = await _connect();

      final items = <String>[];
      Object? error;
      final settled = Completer<void>();
      final sub = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bigStream',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (r) => items.add(r.value.length > 32 ? '<big>' : r.value),
            onError: (Object e) {
              error ??= e;
              if (!settled.isCompleted) settled.complete();
            },
            onDone: () {
              if (!settled.isCompleted) settled.complete();
            },
          );
      addTearDown(sub.cancel);
      await settled.future.timeout(const Duration(seconds: 20));

      expect(items, ['first']);
      expect(
        error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a response inside the limit is unaffected',
    () async {
      // Without this the witnesses would pass on a channel that refused
      // everything.
      final rig = await _connect();
      final r = await _unary(
        rig.caller,
        'small',
      ).timeout(const Duration(seconds: 20));
      expect(r.value, 'ok');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
