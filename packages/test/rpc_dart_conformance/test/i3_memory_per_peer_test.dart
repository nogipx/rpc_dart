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
//   deaf peer      how many calls the server takes from a peer that reads
//                  nothing, counted by the handlers
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
import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

const _knownFailing = <String, String>{
  'websocket | 100000 unary calls answered with a status, peer reads nothing':
      'B-300: the websocket channel reads on while its writes queue',
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

  group('I-3 a peer that never reads is not answered without bound:', () {
    // Each call is answered by a trailer alone, which flow control does not
    // hold back: a DATA answer would park in the send window instead, under
    // the many-streams bound. 100k trailers are ~30 MiB; what the server may
    // take on is its write backlog limit plus the kernel's buffers both ways.
    const calls = 100000;
    const bound = 60000;
    const answer = 32 * 1024;

    for (final member in members) {
      cell(
        member,
        '$calls unary calls answered with a status, peer reads nothing',
        skip: switch (member) {
          SocketMember() || WebSocketMember() => null,
          HttpMember() =>
            'one request per connection at a time: the next is not read '
                'while an answer is unsent (C-76)',
          Http2Member() =>
            'B-301: needs a raw HTTP/2 peer past MAX_CONCURRENT_STREAMS',
          _ => 'no network peer: the other end is code in this process',
        },
        knownFailing: _knownFailing,
        timeout: const Duration(seconds: 40),
        () async {
          final rig = await member.serve() as NetworkRig;
          addTearDown(rig.close);

          final peer = await _deafPeer(rig, calls: calls);
          // Poll up to the threshold (tests item 1).
          final until = DateTime.now().add(const Duration(seconds: 4));
          while (DateTime.now().isBefore(until)) {
            final served = rig.probe.count('received');
            expect(
              served,
              lessThanOrEqualTo(bound),
              reason:
                  'the server took $served calls from a peer that reads '
                  'nothing, and holds every unsent answer',
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }

          // The release: once the peer reads, the server takes the rest.
          // Polled: `waitForCount` recounts every event on every event, which
          // is quadratic at this many calls.
          peer.hear();
          final released = DateTime.now().add(const Duration(seconds: 10));
          var taken = 0;
          while ((taken = rig.probe.count('received')) < peer.written &&
              DateTime.now().isBefore(released)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(
            taken,
            greaterThanOrEqualTo(peer.written),
            reason:
                'the peer reads again, and the server took only $taken of '
                'the ${peer.written} calls it wrote',
          );

          // The valid neighbour: a caller that reads gets the same load
          // answered in full, on the same server.
          final caller = await rig.caller();
          final outcomes = await Future.wait([
            for (var i = 0; i < 400; i++)
              Call.start(
                caller,
                CallShape.unary,
                Blob.request(id: nextCallId(), responseSize: answer),
                deadline: const Duration(seconds: 10),
              ).outcome,
          ]);
          final failed = outcomes.where((o) => !o.ok).toList();
          expect(failed, isEmpty, reason: 'a reading caller was refused');
        },
      );
    }
  });
}

const _batch = 500;

/// Starts [calls] unary calls on [rig]'s server that fail at once, from a peer
/// that does not read its socket until `hear` is called. Returns once every
/// call is written or the server has stopped taking them, with how many were
/// written whole.
Future<({int written, void Function() hear})> _deafPeer(
  NetworkRig rig, {
  required int calls,
}) async {
  final metadata = RpcMetadata.forClientRequest(conformanceService, 'unary');
  // [_batch] calls from the [first]th, in one write: the frame protocol
  // reassembles frames from any chunking, and one call per write leaves the
  // peer too slow to reach the server's limit inside a test's time.
  Uint8List batch(int first) {
    final out = BytesBuilder(copy: false);
    for (var i = first; i < first + _batch && i < calls; i++) {
      final streamId = 2 * i + 1;
      final request = Blob.request(id: nextCallId(), mode: Mode.fail);
      out
        ..add(
          RpcChannelFrame.encodeMetadata(
            streamId: streamId,
            metadata: metadata,
          ),
        )
        ..add(
          RpcChannelFrame.encodeData(
            streamId: streamId,
            payload: RpcMessageFrame.encode(blobCodec.serialize(request)),
            endOfStream: true,
          ),
        );
    }
    return out.takeBytes();
  }

  switch (rig.member) {
    case SocketMember():
      // Read events off: nothing in this process reads the socket.
      final raw = await RawSocket.connect(
        InternetAddress.loopbackIPv4,
        rig.serverPort,
      );
      raw.readEventsEnabled = false;
      addTearDown(raw.close);
      final writable = StreamController<void>.broadcast();
      var reading = false;
      raw.listen((e) {
        if (e == RawSocketEvent.write) writable.add(null);
        if (e == RawSocketEvent.read && reading) raw.read();
      }, onError: (Object _) {});
      // False once the kernel has taken nothing for a second: the server
      // stopped reading.
      Future<bool> write(Uint8List bytes) async {
        var offset = 0;
        while (offset < bytes.length) {
          offset += raw.write(bytes, offset);
          if (offset == bytes.length) break;
          raw.writeEventsEnabled = true;
          var moved = true;
          await writable.stream.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => moved = false,
          );
          if (!moved) return false;
        }
        return true;
      }

      void hear() {
        reading = true;
        raw.readEventsEnabled = true;
      }

      var written = 0;
      if (!await write(RpcSocketChannel.preface)) {
        return (written: 0, hear: hear);
      }
      for (var i = 0; i < calls; i += _batch) {
        if (!await write(batch(i))) break;
        written = i + _batch < calls ? i + _batch : calls;
        // The server runs in this isolate: give it the event loop.
        await Future<void>.delayed(Duration.zero);
      }
      return (written: written, hear: hear);
    case WebSocketMember():
      final ws = await WebSocket.connect('ws://127.0.0.1:${rig.serverPort}');
      addTearDown(ws.close);
      // Paused before anything arrives: dart:io stops reading the socket.
      final sub = ws.listen((_) {}, onError: (Object _) {})..pause();
      for (var i = 0; i < calls; i += _batch) {
        ws.add(batch(i));
        await Future<void>.delayed(Duration.zero);
      }
      return (written: calls, hear: sub.resume);
    default:
      throw UnsupportedError('${rig.member.runtimeType}');
  }
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
    case NetworkRig(member: SocketMember()):
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        rig.serverPort,
      );
      socket.done.catchError((Object _) => socket).ignore();
      addTearDown(socket.destroy);
      final done = socket.drain<void>().catchError((Object _) {});
      socket
        ..add(RpcSocketChannel.preface)
        ..add(
          RpcChannelFrame.encodeMetadata(
            streamId: 1,
            metadata: RpcMetadata.forClientRequest(conformanceService, 'unary'),
          ),
        )
        ..add(partialFrame());
      await socket.flush().catchError((Object _) {});
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
