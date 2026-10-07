// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// HTTP/1.1 cannot flush a response before the end, so a server stream's WHOLE
// output sits in `pending.bodyBuffer` until the handler finishes -- and a
// method that streams until cancelled never does. Nothing capped it.
//
// Measured with an 8 KiB-per-item feed against a 64 KiB ceiling, largest arm
// first so the VM's warm-up is paid in the same place both times:
//
//   8 MiB produced, no cap   peak RSS +57664 KiB
//   8 MiB produced, capped   peak RSS +11456 KiB
//
// And the retention bought nothing: the caller refuses any body over the same
// ceiling, so all three over-limit arms delivered 0 items either way. That is
// what makes ending the stream early strictly better than buffering it --
// the bytes past the ceiling can never be delivered.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _chunk = 8 * 1024;
const _limit = 64 * 1024;

final class _Svc extends RpcResponderContract {
  _Svc(this.count, this.onItem) : super('Svc');

  final int count;
  final void Function() onItem;

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'feed',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        final item = ('x' * _chunk).rpc;
        for (var i = 0; i < count; i++) {
          onItem();
          yield item;
          // A FEED, which is the shape the lead names: a subscription or a tail
          // that produces over time. Without an await the whole loop runs in
          // one turn, and then "how much had been produced when the caller was
          // answered" is 100% whatever the transport does.
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      },
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, int Function() produced});

Future<_Rig> _serve(int count) async {
  var produced = 0;
  const policy = RpcSecurityPolicy(maxMessageLengthBytes: _limit);
  final responder = RpcHttpResponderTransport(securityPolicy: policy);
  final endpoint = RpcResponderEndpoint(transport: responder)
    ..registerServiceContract(_Svc(count, () => produced++)..setup())
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
  return (caller: caller, produced: () => produced);
}

Future<({int received, Object? error})> _drain(RpcCallerEndpoint caller) async {
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

void main() {
  test(
    'WITNESS: a stream past the ceiling is ended, not accumulated',
    () async {
      // 200 items of 8 KiB = 1.6 MiB against a 64 KiB ceiling: 8 items fit.
      final rig = await _serve(200);
      final out = await _drain(rig.caller);
      // The handler's own counter AT THE MOMENT the caller was answered. This
      // is the assertion that distinguishes: the caller saw RESOURCE_EXHAUSTED
      // before the fix too — by refusing the whole body it had already been
      // sent — so the status alone proves nothing. What changed is WHEN the
      // answer comes: at the ceiling, not at the end of the handler.
      final producedWhenAnswered = rig.produced();

      expect(
        out.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
      );
      expect(out.received, 0);
      expect(
        producedWhenAnswered,
        lessThan(200),
        reason:
            'the answer waited for the handler to finish, which means the '
            'whole 1.6 MiB was resident first',
      );
      expect(
        (out.error! as RpcStatusException).message,
        contains('HTTP/1.1 cannot stream it'),
        reason: 'the refusal came from the caller, not from the server',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: the ceiling must not end a stream that FITS. Without this, a
  // responder that refused every server stream would pass the witness.
  test(
    'GUARD: a stream under the ceiling is delivered whole',
    () async {
      final rig = await _serve(4);
      final out = await _drain(rig.caller);

      expect(out.error, isNull);
      expect(out.received, 4);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // The handler is STOPPED once the stream is answered: the transport tells
  // the pipeline the way a peer cancellation is told. Without it the handler
  // ran to completion with its output dropped, holding its slot meanwhile.
  test(
    'the handler is cancelled once the stream is ended',
    () async {
      final rig = await _serve(200);
      await _drain(rig.caller);
      final atAnswer = rig.produced();

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        rig.produced(),
        lessThan(200),
        reason: 'the handler must not run to completion',
      );
      expect(rig.produced() - atAnswer, lessThan(5));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
