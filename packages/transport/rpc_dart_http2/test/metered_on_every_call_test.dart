// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// getMessagesForStream must return a FLOW-CONTROL-METERED stream on every call,
// not only the first.
//
// Round 308 found the caller doing this:
//
//     final existing = _streamControllers[streamId];
//     if (existing != null) return existing.stream;        // NOT metered
//     ...
//     return _fcMetered(streamId, ctl.stream);             // metered
//
// Both calls hand back the SAME controller's stream, so whichever call the
// consumer listens to is the only listen there is. Take the second one and
// nothing discharges `_fcOutstanding` as bytes are consumed: the counter only
// climbs, and the call is failed at `_fcWindow` for bytes it did in fact read.
//
// The responder sibling — twenty near-identical lines in another file of this
// package — metered both paths and was correct. Neither file imports the other,
// the analyzer sees two valid methods, and every existing test passes, because
// asking twice for one stream is the uncommon path. Round 308's own record said
// so: "the test suite is not the witness here". This is that witness.
//
// The bound is 4 MiB (RpcSecurityPolicy.flowControlWindowBytes, resolved by
// `unconsumedWindowFor`), so the stream below sends 5 MiB in 20 chunks of
// 256 KiB — enough to cross it, small enough to stay quick.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _chunkBytes = 256 * 1024;
const _chunks = 30;

/// A body that does NOT compress.
///
/// The first version of this test yielded `'z' * 256KiB` and measured 303 bytes
/// per frame arriving instead of 262144: the payload is charged against the
/// window as it appears ON THE WIRE, and a run of one character deflates about
/// 900:1. Thirty of those never approach a 4 MiB bound, so the test passed on
/// broken code by never reaching the mechanism — which is what the byte guard
/// below exists to catch.
final String _body = () {
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final buf = StringBuffer();
  var x = 123456789;
  for (var i = 0; i < _chunkBytes; i++) {
    x = (1103515245 * x + 12345) & 0x7FFFFFFF;
    buf.writeCharCode(alphabet.codeUnitAt(x % alphabet.length));
  }
  return buf.toString();
}();

final class _BulkContract extends RpcResponderContract {
  _BulkContract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Bulk',
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < _chunks; i++) {
          yield _body.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'a repeat getMessagesForStream is metered too',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_BulkContract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );

      // Driven at the TRANSPORT level on purpose: the endpoint pipeline asks
      // for a stream once, so it cannot reach the second-call path at all.
      final id = transport.createStream();
      await transport.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'Bulk'),
      );
      await transport.sendMessage(
        id,
        // The library's own serializer, not a hand-built body: the wire format
        // is CBOR and nothing in the request shape says so (lesson L-10).
        ensureGrpcFrame(_codec.serialize('go'.rpc)),
        endStream: true,
      );

      // The first view is never listened to. Both calls return the same
      // controller's stream, so this is the whole defect: which call did the
      // consumer get?
      transport.getMessagesForStream(id);
      final second = transport.getMessagesForStream(id);

      var payloadBytes = 0;
      Object? failure;
      String? trailerStatus;
      String? trailerMessage;
      final done = Completer<void>();

      var frames = 0;
      second.listen(
        (m) {
          frames++;
          payloadBytes += m.payload?.length ?? 0;
          final headers = m.metadata?.headers;
          if (headers != null) {
            for (final h in headers) {
              if (h.name == RpcHeaders.grpcStatus) trailerStatus = h.value;
              if (h.name == RpcHeaders.grpcMessage) trailerMessage = h.value;
            }
          }
          if (trailerStatus != null && !done.isCompleted) done.complete();
        },
        onError: (Object e) {
          failure ??= e;
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future.timeout(const Duration(seconds: 60));

      // Unmetered, the counter reaches 5 MiB against a 4 MiB window and the
      // call is failed with RESOURCE_EXHAUSTED plus an RST_STREAM.
      expect(
        failure,
        isNull,
        reason:
            'the repeat getMessagesForStream was not metered: consuming '
            '$payloadBytes bytes never discharged the un-consumed window, so '
            'the call was failed for bytes it had actually read',
      );
      expect(
        payloadBytes,
        greaterThan(_chunks * _chunkBytes ~/ 2),
        reason:
            'only $payloadBytes bytes in $frames frame(s) arrived '
            '(grpc-status $trailerStatus, $trailerMessage); the stream was cut '
            'short before it could cross the window at all, so this run proves '
            'nothing',
      );

      await transport.close().catchError((Object _) {});
      await server.stop();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
