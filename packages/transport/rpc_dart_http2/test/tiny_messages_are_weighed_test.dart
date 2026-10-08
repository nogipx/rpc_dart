// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// HTTP/2 request queues have no depth bound (IRpcNoMessageCredit), so the byte
// totals are all that bounds them. A queued message retains about a hundred
// bytes whatever its payload, and charged its payload alone, a queue of
// two-byte messages passed the connection total thirty-fold: eight parked
// streams held 413 MiB. Each message is now charged what it retains.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _streams = 2;
const _perStream = 50000;

final class _Svc extends RpcResponderContract {
  _Svc(this.release) : super('Svc');
  final Future<void> release;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        await release;
        var n = 0;
        await for (final _ in requests) {
          n++;
        }
        return '$n'.rpc;
      },
    );
  }
}

var _pulled = 0;

Stream<RpcString> _tiny() async* {
  for (var i = 0; i < _perStream; i++) {
    _pulled++;
    yield 'x'.rpc;
    if (i % 2000 == 0) await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'WITNESS a queue of tiny messages is refused at the connection total',
    () async {
      final release = Completer<void>();
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        // 100k messages of 2 payload bytes are 200 KB by payload and about
        // 13 MB by retention.
        securityPolicy: const RpcSecurityPolicy(
          flowControlConnectionWindowBytes: 4 * 1024 * 1024,
        ),
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Svc(release.future)),
      );
      await server.start();
      final caller = RpcCallerEndpoint(
        transport: await RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: server.port,
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await caller.close();
        await server.stop();
      });

      final refused = <int>[];
      final calls = [
        for (var s = 0; s < _streams; s++)
          caller
              .clientStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'Upload',
                requestCodec: _codec,
                responseCodec: _codec,
              )(_tiny())
              .then<void>(
                (_) {},
                onError: (Object e) {
                  if (e is RpcStatusException) refused.add(e.statusCode);
                },
              ),
      ];

      // Everything queued behind the parked handlers, then let them read: a
      // refused queue reaches the handler as an error, and so the caller.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (_pulled < _streams * _perStream &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      release.complete();
      await Future.wait(calls).timeout(const Duration(seconds: 20));

      expect(
        refused,
        isNotEmpty,
        reason: 'the queue passed the connection total without a refusal',
      );
      expect(refused, everyElement(RpcStatus.resourceExhausted));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
