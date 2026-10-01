// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// On HTTP/2 only an OPENING frame can carry client metadata -- `makeRequest`
// opens a stream rather than addressing one. `sendMetadata` defaulted a missing
// methodPath to '/Unknown/Unknown' and opened one anyway, and core sends exactly
// such a frame: the cancellation notice, after `resetStream` reports it could not
// deliver the cancel, which happens when the id has no stream.
//
// Measured against a server recording every `:path` it accepted:
//
//     cancel after the call completed   [/Svc/Echo, /Unknown/Unknown]
//     a second opening frame, live id   [/Svc/Slow, /Svc/Again], activeStreams 1
//
// The second row is the other half: `_activeStreams[streamId] = stream`
// overwrote, so the first stream was stranded with nothing tracking it while the
// count still read 1.
//
// The same defect the HTTP/1.1 caller already fixed -- see its sendMetadata.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Every stream the server accepted, by its `:path`.
final List<String> _paths = [];

/// A server that records paths and, when [answer] is false, never responds -- so
/// the stream stays LIVE, which is what the overwrite case needs. An answering
/// server ends it first and a second frame then takes the no-methodPath branch.
Future<ServerSocket> _server({bool answer = true}) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      var recorded = false;
      stream.incomingMessages.listen((m) {
        if (m is http2.HeadersStreamMessage && !recorded) {
          recorded = true;
          for (final h in m.headers) {
            if (String.fromCharCodes(h.name) == ':path') {
              _paths.add(String.fromCharCodes(h.value));
            }
          }
        }
      }, onError: (Object _) {});
      if (!answer) return;
      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc+proto'),
      ]);
      stream.sendData(
        RpcMessageFrame.encode(_codec.serialize('ok'.rpc), compressed: false),
      );
      stream.sendHeaders([
        http2.Header.ascii('grpc-status', '0'),
      ], endStream: true);
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

/// What `base_processor._notifyPeerOfCancellation` falls back to when
/// `resetStream` returns false: no methodPath.
RpcMetadata _cancellationMetadata() => RpcMetadata([
  const RpcHeader(RpcHeaders.xClientCancelled, 'true'),
  const RpcHeader(RpcHeaders.xCancellationReason, 'test'),
  RpcHeader(RpcHeaders.grpcStatus, RpcStatus.cancelled.toString()),
]);

void main() {
  setUp(_paths.clear);

  // WITNESS. Before: [/Svc/Echo, /Unknown/Unknown].
  test('a cancel for a released id opens no stream', () async {
    final socket = await _server();
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await socket.close();
    });

    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 8));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(_paths, ['/Svc/Echo'], reason: 'the call itself must have happened');

    final staleId = transport.lastIssuedStreamId;
    // GUARD on the premise: the fallback core takes runs only when this is false.
    expect(
      await transport.resetStream(staleId, reason: 'test'),
      isFalse,
      reason:
          'a released id has no stream to reset, which is what sends the '
          'cancellation notice through sendMetadata instead',
    );

    await transport
        .sendMetadata(staleId, _cancellationMetadata(), endStream: true)
        .catchError((Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      _paths,
      ['/Svc/Echo'],
      reason:
          'a cancel is not a request; opening /Unknown/Unknown gives the '
          'server a call it must answer and leaves the real one untouched',
    );
  });

  // WITNESS, the other half. Before: [/Svc/Slow, /Svc/Again] with activeStreams
  // still 1, the first stream stranded.
  test('a second opening frame on a live id is refused', () async {
    final socket = await _server(answer: false);
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
    addTearDown(() async {
      await transport.close().catchError((Object _) {});
      await socket.close();
    });

    final id = transport.createStream();
    await transport.sendMetadata(
      id,
      RpcMetadata.forClientRequest('Svc', 'Slow'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      (await transport.health()).details['activeStreams'],
      1,
      reason: 'the arm needs the first stream still LIVE',
    );

    await expectLater(
      transport.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'Again')),
      throwsA(isA<RpcStatusException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(_paths, ['/Svc/Slow'], reason: 'no second stream may be opened');
    expect(
      (await transport.health()).details['activeStreams'],
      1,
      reason: 'the first stream is still the one being tracked',
    );
  });

  // CONTROL. An ordinary call still opens exactly one stream, so the refusals
  // above are about the two cases named and not about metadata having stopped
  // working.
  test('CONTROL: an ordinary call still opens its stream', () async {
    final socket = await _server();
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await socket.close();
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

    expect(r.value, 'ok');
    expect(_paths, ['/Svc/Echo']);
  });
}
