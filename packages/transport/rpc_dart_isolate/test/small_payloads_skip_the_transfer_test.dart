// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The channel sent EVERY payload as `TransferableTypedData`, under a doc claiming
// "bytes cross without a copy". `fromList` copies while building and adds a native
// allocation and a finaliser, which the small frames this transport mostly carries --
// window grants and headers -- cannot amortise. Measured round-trip, us/frame,
// minimum of three runs:
//
//        32 B    TTD   2.71   Uint8List   2.34
//      1 KiB     TTD   2.66   Uint8List   2.33
//     64 KiB     TTD  11.26   Uint8List   7.87
//    128 KiB     TTD  20.44   Uint8List  14.03
//    256 KiB     TTD 103.71   Uint8List 160.67
//      1 MiB     TTD 383.08   Uint8List 486.63
//
// So the flat claim was wrong in BOTH directions, and the fix is a threshold rather
// than a replacement. What this test pins is that both sides of it still deliver the
// bytes intact -- the rate is P-199's job, not a test's.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void _echoEntry(IRpcTransport transport, Map<String, dynamic> params) {
  final responder = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_EchoLength())
    ..start();
  // The endpoint owns the transport for the isolate's life.
  assert(responder.runtimeType == RpcResponderEndpoint);
}

final class _EchoLength extends RpcResponderContract {
  _EchoLength() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'length',
      requestCodec: _codec,
      responseCodec: _codec,
      // Answers with the byte count it actually received, so a payload truncated or
      // mangled in transit shows up as a wrong number rather than as a hang.
      handler: (r, {RpcContext? context}) async => '${r.value.length}'.rpc,
    );
  }
}

void main() {
  test(
    'payloads on both sides of the transfer threshold arrive intact',
    () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: _echoEntry,
        isolateId: 'threshold',
      );
      final caller = RpcCallerEndpoint(transport: spawned.transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        spawned.kill();
      });

      // 1 KiB is well under the 256 KiB threshold and 512 KiB well over, so one call
      // each exercises the plain-list path and the transfer path.
      for (final size in [1024, 512 * 1024]) {
        final body = String.fromCharCodes(
          Uint8List(size)..fillRange(0, size, 65),
        );
        final reply = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'length',
              request: body.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 30));

        expect(
          reply.value,
          '$size',
          reason:
              'a $size-byte payload must arrive whole whichever side of the '
              'threshold it falls on',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
