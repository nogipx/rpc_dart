// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream CALLER is the sender of the upload, and for a stream it opened
// an inbound end-of-stream is the response's last frame, so the transport drops
// the stream's flow-control state there. A server that answers before reading
// the whole upload ends the call while the caller is still sending and may be
// parked on the window. The call must still complete, and nothing may be left
// behind on either side.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
const _kib = 1024;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      handler: (requests, {RpcContext? context}) async {
        // Reads one message and stops consuming, so the caller fills the window
        // and parks; then answers without reading the rest.
        final it = StreamIterator(requests);
        await it.moveNext();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return 'enough'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'count',
      handler: (requests, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
        }
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<bool> _settles(bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return done();
}

void main() {
  test(
    'an answer before the upload is read ends the call and leaves no state',
    () async {
      final (client, server) = RpcChannelTransport.pair(
        policy: const RpcSecurityPolicy(
          flowControlWindowBytes: 64 * _kib,
          flowControlConnectionWindowBytes: null,
          initialSendWindowBytes: 64 * _kib,
        ),
      );
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Svc())
        ..start();
      final caller = RpcCallerEndpoint(transport: client);

      // Far more than one window, produced on demand.
      var produced = 0;
      Stream<RpcString> upload() async* {
        final chunk = ('z' * _kib).rpc;
        for (var i = 0; i < 2000; i++) {
          produced++;
          yield chunk;
        }
      }

      final answer = await caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'upload',
            requestCodec: _codec,
            responseCodec: _codec,
          )(upload())
          .timeout(const Duration(seconds: 10));
      expect(answer.value, 'enough');
      expect(
        produced,
        inInclusiveRange(60, 100),
        reason: 'the window must have parked the upload before the answer',
      );

      final callerIdle = await _settles(
        () => client.flowControlStateSizes.values.every((v) => v == 0),
      );
      expect(
        callerIdle,
        isTrue,
        reason: 'caller state left behind: ${client.flowControlStateSizes}',
      );

      // And the connection still serves an ordinary upload afterwards.
      final count = await caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'count',
            requestCodec: _codec,
            responseCodec: _codec,
          )(Stream.fromIterable(List.filled(300, ('y' * _kib).rpc)))
          .timeout(const Duration(seconds: 10));
      expect(count.value, '300');

      await caller.close();
      await responder.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
