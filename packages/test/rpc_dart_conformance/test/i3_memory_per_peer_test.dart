// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-3 -- memory per peer is bounded.
//
// Memory held for one connection stays within a bound derived from the
// configured limits, whatever the peer sends or withholds: unfinished frames
// or headers, pings, a paused read, many streams.
//
// RSS is not evidence (L-23). Each row reads something the LIBRARY does:
//   paused read    how far the handler's producer gets past a paused caller,
//                  counted by the handler itself
//   many streams   how many handlers the server runs at once, counted by the
//                  handlers, against the server's maxActiveStreams
//   unfinished     the server refusing (closing, or answering with a status)
//                  a message that is still arriving past the limit, before
//                  the peer has finished it
//   pings          the server closing a connection that pings without end
// A member with no such observable for a row is skipped with the reason.
//
// Every refusal is paired with the valid neighbour (tests item 5): admitted
// streams rise to the limit; a message AT the limit, on a fresh connection to
// the same server, is delivered. The receiving side alone has the small limit
// (L1).

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as h2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

/// Measured: 172 messages at the first sample over the bound; left alone, the
/// producer runs to maxBufferedMessagesPerStream + 1 (8193 messages of
/// 1 KiB), or to the 4000-message cap of this row (64 MiB). Channel and
/// websocket under the same policy stop at 33.
const _knownFailing = <String, String>{
  'isolate | server stream, caller paused':
      'the handler produced 172 messages of 16384 bytes past a paused caller; '
      'the policy bounds it near 104. The byte window does not pace the '
      'isolate transport: only the message credit (8192) does',
};

const _httpDiscards =
    'no library-side observable while the body arrives: past the limit the '
    'http responder discards the rest of the body silently and answers 413 '
    'only when the body ends (measured: 8 MiB of a chunked body sent to a '
    '64 KiB limit, no answer until the final chunk)';

const _onePolicy =
    'spawn applies one policy to both sides, so the caller\'s own ceiling '
    'refuses first and the server\'s bound is never reached (L1)';

const _noFrames =
    'no byte framing: a message crosses the SendPort whole, so it can never '
    'be unfinished';

void main() {
  group('I-3 a paused reader holds the producer:', () {
    const policy = RpcSecurityPolicy(
      maxMessageLengthBytes: 128 * 1024,
      flowControlWindowBytes: 512 * 1024,
    );
    const size = 16 * 1024;
    // Twice what the policy lets one stream hold, in messages: the producer
    // may be ahead of the window by what sits in the layers above it.
    final bound = 2 * policy.effectiveStreamBufferBytes ~/ size + 16;

    for (final member in members) {
      cell(
        member,
        'server stream, caller paused',
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve(serverPolicy: policy);
          addTearDown(rig.close);
          final caller = await rig.caller(policy: policy);
          final id = nextCallId();

          final call = Call.start(
            caller,
            CallShape.serverStream,
            Blob.request(
              id: id,
              mode: Mode.produce,
              responseSize: size,
              count: 4000,
            ),
            deadline: const Duration(seconds: 5),
            pauseResponses: const Duration(days: 1),
          );
          addTearDown(call.cancel);
          await rig.probe.waitFor('produced', id);

          // Poll up to the threshold (tests item 1): an unbounded producer
          // crosses it well inside this window.
          final until = DateTime.now().add(const Duration(milliseconds: 600));
          while (DateTime.now().isBefore(until)) {
            final produced = rig.probe.maxN('produced', id);
            expect(
              produced,
              lessThanOrEqualTo(bound),
              reason:
                  'the handler produced $produced messages of $size bytes past '
                  'a paused caller; the policy bounds it near $bound',
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        },
      );
    }
  });

  group('I-3 streams past the server limit are not served:', () {
    const limit = 8;
    const serverPolicy = RpcSecurityPolicy(maxActiveStreams: limit);

    for (final member in members) {
      cell(
        member,
        '${limit * 2} calls, server maxActiveStreams $limit',
        skip: member is IsolateMember ? _onePolicy : null,
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve(serverPolicy: serverPolicy);
          addTearDown(rig.close);
          final caller = await rig.caller();

          final calls = [
            for (var i = 0; i < limit * 2; i++)
              Call.start(
                caller,
                CallShape.unary,
                Blob.request(id: nextCallId(), mode: Mode.hang),
                deadline: const Duration(seconds: 3),
              ),
          ];
          for (final c in calls) {
            addTearDown(c.cancel);
          }
          // The valid neighbour: the limit itself is admitted.
          await rig.probe.waitForCount('enter', limit);
          final until = DateTime.now().add(const Duration(milliseconds: 400));
          while (DateTime.now().isBefore(until)) {
            expect(
              rig.probe.count('enter'),
              lessThanOrEqualTo(limit),
              reason: 'the server ran more handlers than maxActiveStreams',
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        },
      );
    }
  });

  group('I-3 an oversized message that never finishes is refused:', () {
    const limit = 64 * 1024;
    const serverPolicy = RpcSecurityPolicy(maxMessageLengthBytes: limit);

    for (final member in members) {
      cell(
        member,
        'limit + 32 KiB of a ${2 * limit}-byte message, then nothing',
        skip: switch (member) {
          IsolateMember() => _noFrames,
          HttpMember() => _httpDiscards,
          _ => null,
        },
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve(serverPolicy: serverPolicy);
          addTearDown(rig.close);

          // The message claims twice the limit; the peer sends the limit and
          // 32 KiB more of it and then withholds the rest.
          final message = RpcMessageFrame.encode(Uint8List(2 * limit));
          const sent = limit + 32 * 1024;
          await _refusedWhileArriving(rig, message, sent).timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail(
              'the server neither closed nor answered while holding '
              '$sent bytes of a message over its $limit-byte limit',
            ),
          );

          // The valid neighbour, on the same server.
          final outcome = await Call.start(
            await rig.caller(),
            CallShape.unary,
            Blob.request(id: nextCallId(), size: limit),
            deadline: const Duration(seconds: 2),
          ).outcome;
          expect(
            outcome.ok,
            isTrue,
            reason: 'a message at the limit: $outcome',
          );
        },
      );
    }
  });

  group('I-3 a connection that pings without end is closed:', () {
    for (final member in members) {
      cell(
        member,
        'ping flood',
        skip: switch (member) {
          WebSocketMember() => null,
          Http2Member() =>
            'no library-side observable: rpc_dart_http2 neither counts nor '
                'refuses inbound PINGs; package:http2 answers each one',
          HttpMember() => 'HTTP/1.1 has no ping',
          _ =>
            'the rpc_dart frame protocol has no transport ping; an '
                'application ping is a stream, bounded by the many-streams row',
        },
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve() as NetworkRig;
          addTearDown(rig.close);
          final uri = 'ws://127.0.0.1:${rig.serverPort}';

          // The valid neighbour: a client pinging 5 times a second stays.
          final calm = await WebSocket.connect(uri);
          calm.pingInterval = const Duration(milliseconds: 200);
          addTearDown(calm.close);
          var calmClosed = false;
          calm.listen((_) {}, onDone: () => calmClosed = true);

          final flood = await WebSocket.connect(uri);
          flood.pingInterval = const Duration(milliseconds: 1);
          addTearDown(flood.close);
          await flood
              .drain<void>()
              .catchError((Object _) {})
              .timeout(
                const Duration(seconds: 3),
                onTimeout: () => fail('a client pinging 1000/s was not closed'),
              );
          expect(calmClosed, isFalse, reason: 'the calm client was closed too');
        },
      );
    }
  });
}

/// Sends the first [count] bytes of the gRPC-framed request [message] to
/// [rig]'s server the raw way, in the transport's own framing, and completes
/// when the server refuses it: closes the connection, or answers.
Future<void> _refusedWhileArriving(
  Rig rig,
  Uint8List message,
  int count,
) async {
  final bytes = Uint8List.sublistView(message, 0, count);
  // rpc_dart frame protocol: a data frame whose header claims the whole
  // message, cut after [count] bytes of it.
  Uint8List partialFrame() => Uint8List.sublistView(
    RpcChannelFrame.encodeData(streamId: 1, payload: message),
    0,
    RpcChannelFrame.headerSize + count,
  );
  switch (rig) {
    case ChannelRig():
      final end = rig.rawToServer();
      final done = end.incoming.drain<void>();
      await end.send(
        RpcChannelFrame.encodeMetadata(
          streamId: 1,
          metadata: RpcMetadata.forClientRequest(conformanceService, 'unary'),
        ),
      );
      await end.send(Uint8List.fromList(partialFrame()));
      await done;
    case NetworkRig(member: WebSocketMember()):
      final ws = await WebSocket.connect('ws://127.0.0.1:${rig.serverPort}');
      final done = ws.drain<void>().catchError((Object _) {});
      ws.add(
        RpcChannelFrame.encodeMetadata(
          streamId: 1,
          metadata: RpcMetadata.forClientRequest(conformanceService, 'unary'),
        ),
      );
      ws.add(partialFrame());
      await done;
    case NetworkRig(member: Http2Member()):
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        rig.serverPort,
      );
      socket.done.catchError((Object _) => socket).ignore();
      final conn = h2.ClientTransportConnection.viaSocket(socket);
      addTearDown(() => conn.terminate().catchError((Object _) {}));
      final stream = conn.makeRequest([
        h2.Header.ascii(':method', 'POST'),
        h2.Header.ascii(':path', '/$conformanceService/unary'),
        h2.Header.ascii(':scheme', 'http'),
        h2.Header.ascii(':authority', '127.0.0.1'),
        h2.Header.ascii('content-type', 'application/grpc'),
        h2.Header.ascii('te', 'trailers'),
      ]);
      stream.sendData(bytes);
      // Any answer on the stream, or its end, is the refusal.
      await stream.incomingMessages.first.catchError(
        (Object _) => h2.DataStreamMessage(const []),
      );
    case NetworkRig(member: HttpMember()):
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        rig.serverPort,
      );
      socket.done.catchError((Object _) => socket).ignore();
      addTearDown(socket.destroy);
      final answered = Completer<void>();
      socket.listen(
        (_) {
          if (!answered.isCompleted) answered.complete();
        },
        onError: (Object _) {},
        onDone: () {
          if (!answered.isCompleted) answered.complete();
        },
        cancelOnError: true,
      );
      socket.add(
        'POST /$conformanceService/unary HTTP/1.1\r\n'
                'host: 127.0.0.1\r\n'
                'content-type: application/grpc\r\n'
                'transfer-encoding: chunked\r\n\r\n'
            .codeUnits,
      );
      for (var i = 0; i < bytes.length; i += 8192) {
        final end = i + 8192 < bytes.length ? i + 8192 : bytes.length;
        socket.add('${(end - i).toRadixString(16)}\r\n'.codeUnits);
        socket.add(Uint8List.sublistView(bytes, i, end));
        socket.add('\r\n'.codeUnits);
      }
      await socket.flush().catchError((Object _) {});
      await answered.future;
    default:
      throw UnsupportedError('${rig.runtimeType}');
  }
}
