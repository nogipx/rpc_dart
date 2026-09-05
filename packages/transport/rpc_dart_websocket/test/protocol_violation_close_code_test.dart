// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A framing violation is DETERMINISTIC: the peer sent something malformed and
// will send it again if it believes the failure was transient. The channel used
// to be torn down silently, so a WebSocket peer saw close code 1005 "no status
// received", which maps to UNAVAILABLE -- retryable. The peer was being invited
// to repeat the frame that had just got it disconnected.
//
// Measured against an rpc_dart server, before:
//
//   server shutdown           : 1005 -> UNAVAILABLE (retryable)  correct
//   client protocol violation : 1005 -> UNAVAILABLE (retryable)  WRONG
//   endpoint closed           : 1005 -> UNAVAILABLE (retryable)  correct
//
// after, the violation alone changes:
//
//   client protocol violation : 4400 -> UNKNOWN (not retried), with the reason
//                               "Incoming frame payload too large: 67108864
//                                bytes (max: 1029)"
//
// The other two are untouched: a shutdown or a closed endpoint SHOULD be
// retryable, and a client reconnecting past a restart is the normal case.
//
// On the close code itself: 1002 "protocol error" is what this means and it
// cannot be sent. An application may only use 1000 or 3000-4999 --
// `package:web_socket` rejects the rest with "close code must be 1000 or in
// the range 3000-4999", which made the first version of this throw on the
// teardown path. 4400 is in the private range, echoes HTTP 400, and maps to
// UNKNOWN, which is not retried. That is the property under test.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

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

void main() {
  late HttpServer http;
  final endpoints = <RpcResponderEndpoint>[];

  Future<void> boot({
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  }) async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.transform(WebSocketTransformer()).listen((ws) {
      final transport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(ws),
        policy: policy,
      );
      final endpoint = RpcResponderEndpoint(transport: transport);
      endpoint.registerServiceContract(_Contract());
      endpoint.start();
      endpoints.add(endpoint);
    });
  }

  tearDown(() async {
    for (final e in endpoints) {
      await e.close().catchError((Object _) {});
    }
    endpoints.clear();
    await http.close(force: true);
  });

  /// Connects raw, runs [act], and reports the close code the server used.
  Future<({int? code, String? reason})> observeClose(
    Future<void> Function(IOWebSocketChannel ws) act,
  ) async {
    final ws = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    await ws.ready;
    final done = Completer<void>();
    ws.stream.listen(
      (_) {},
      onError: (Object _) {},
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    await act(ws);
    await done.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
    return (code: ws.closeCode, reason: ws.closeReason);
  }

  test(
    'a framing violation closes with a non-retryable code',
    () async {
      // A frame budget small enough that the declared payload below breaches it.
      await boot(policy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024));

      final closed = await observeClose((ws) async {
        // Real header layout: 4 bytes streamId, 1 byte flags, 4 bytes length.
        final header = Uint8List(RpcChannelFrame.headerSize);
        header.buffer.asByteData()
          ..setUint32(0, 1)
          ..setUint8(4, 0)
          ..setUint32(5, 64 * 1024 * 1024);
        ws.sink.add(header);
        await Future<void>.delayed(const Duration(seconds: 2));
      });

      expect(
        closed.code,
        isNotNull,
        reason: 'the server must say why it hung up',
      );
      expect(
        closed.code,
        isNot(1005),
        reason:
            '1005 "no status received" maps to UNAVAILABLE, which is retryable, '
            'so the peer resends the frame that just got it disconnected',
      );
      expect(
        grpcStatusFromWebSocketCloseCode(closed.code),
        isNot(RpcStatus.unavailable),
        reason: 'a deterministic rejection must not be reported as transient',
      );
      expect(
        closed.reason,
        contains('too large'),
        reason: 'the reason carries the diagnostic a human needs',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary shutdown stays retryable',
    () async {
      // The whole point of distinguishing them. A client SHOULD reconnect past a
      // restart, so this path must keep producing a retryable status.
      await boot();

      final closed = await observeClose((ws) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        for (final e in endpoints) {
          await e.close().catchError((Object _) {});
        }
      });

      expect(
        grpcStatusFromWebSocketCloseCode(closed.code),
        RpcStatus.unavailable,
        reason: 'a shutdown is transient and must remain retryable',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a healthy connection is unaffected',
    () async {
      await boot();
      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ok');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
