// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// On HTTP/1.1 one body is a whole STREAM, and both body reads bounded it by the
// per-MESSAGE limit. So `maxBufferedBytes` — "max buffered bytes for
// reassembly/parsing", the knob whose name means exactly this — bounded nothing
// here, and a finite server stream over 16 MiB could not be allowed by any
// configuration.
//
// Measured on the defaults, against the same contract over a channel pair:
//
//   1500 x 10 B    http FAILED status=8    channel OK 1500
//   20 x 1 MiB     http FAILED status=8    channel OK 20
//   100 x 10 B     http OK 100             channel OK 100
//
// There are TWO ceilings and they are raised by different knobs, which is what
// the class doc now says:
//
//   +maxBufferedBytes       20 x 1 MiB   OK 20
//   +maxMessagesPerChunk    1500 x 10 B  OK 1500
//
// The DEFAULTS are deliberately unchanged: the first table still reads the same.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.count, this.size) : super('Svc');

  final int count;
  final int size;

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'feed',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        final item = ('x' * size).rpc;
        for (var i = 0; i < count; i++) {
          yield item;
        }
      },
    );
  }
}

Future<({int received, Object? error})> _stream({
  required int count,
  required int size,
  required RpcSecurityPolicy policy,
}) async {
  final responder = RpcHttpResponderTransport(securityPolicy: policy);
  final endpoint = RpcResponderEndpoint(transport: responder)
    ..registerServiceContract(_Svc(count, size)..setup())
    ..start();
  final server = await shelf_io.serve(responder.handler, '127.0.0.1', 0);
  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.port}',
      policy: policy,
    ),
  );
  addTearDown(() async {
    await caller.close();
    await endpoint.close();
    await server.close(force: true);
  });

  var received = 0;
  Object? error;
  try {
    await for (final _ in caller.serverStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'feed',
      request: 'go'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )) {
      received++;
    }
  } catch (e) {
    error = e;
  }
  return (received: received, error: error);
}

// 20 x 32 KiB = 640 KiB against a 256 KiB default-equivalent ceiling.
const _small = RpcSecurityPolicy(maxMessageLengthBytes: 256 * 1024);
const _raisedBytes = RpcSecurityPolicy(
  maxMessageLengthBytes: 256 * 1024,
  maxBufferedBytes: 4 * 1024 * 1024,
);

void main() {
  test(
    'WITNESS: maxBufferedBytes raises what one stream may total',
    () async {
      final out = await _stream(
        count: 20,
        size: 32 * 1024,
        policy: _raisedBytes,
      );

      expect(
        out.error,
        isNull,
        reason:
            'the body is bounded by the per-MESSAGE limit, so the knob that '
            'means "buffered bytes" bounds nothing here',
      );
      expect(out.received, 20);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: the DEFAULT is unchanged — the same stream still fails',
    () async {
      final out = await _stream(count: 20, size: 32 * 1024, policy: _small);

      expect(
        out.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
      );
      expect(out.received, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: a stream inside both ceilings is unaffected',
    () async {
      final out = await _stream(count: 4, size: 32 * 1024, policy: _small);

      expect(out.error, isNull);
      expect(out.received, 4);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: there are TWO ceilings, which is the part of the class doc a reader
  // most needs. Bytes raised alone does not lift the message COUNT, because the
  // body reaches the parser as one chunk.
  test(
    'GUARD: raising bytes alone does not lift the message count',
    () async {
      final out = await _stream(count: 1500, size: 10, policy: _raisedBytes);

      expect(
        out.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
        reason: 'maxMessagesPerChunk is the other ceiling and is raised alone',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: raising the count knob lifts it',
    () async {
      final out = await _stream(
        count: 1500,
        size: 10,
        policy: const RpcSecurityPolicy(
          maxMessageLengthBytes: 256 * 1024,
          maxMessagesPerChunk: 100000,
        ),
      );

      expect(out.error, isNull);
      expect(out.received, 1500);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
