// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Hostile peers for I-4, in both directions: a raw client that sends a server
// garbage, and a fake server that answers a real client with garbage.
//
// Four kinds of garbage, from no protocol at all to the right protocol with
// the wrong content:
//   random     bytes from a seeded generator
//   corrupted  a recorded valid exchange with bytes flipped part-way through
//   truncated  the first half of a recorded valid exchange, then the socket
//              is dropped
//   framed     the transport's own framing, built with the library's encoders
//              (L-10), carrying payloads no codec can read
//
// The recordings come from a real call through a recording proxy or pipe, so
// "valid" is whatever the library actually sends today.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as h2;
import 'package:rpc_dart/rpc_dart.dart';

import 'calls.dart';
import 'contract.dart';
import 'members.dart';
import 'peer.dart';
import 'pipe.dart';
import 'tcp_peer.dart';

/// The kinds of garbage.
enum Garbage { random, corrupted, truncated, framed }

/// Bytes of one valid unary exchange, each direction.
typedef Exchange = ({List<int> c2s, List<int> s2c});

const _wait = Duration(seconds: 2);

/// Records one valid unary call to [rig]'s server.
Future<Exchange> recordExchange(Rig rig) async {
  final probe = Blob.request(id: nextCallId(), responseSize: 512);
  switch (rig) {
    case NetworkRig():
      final proxy = await TcpProxy.start(
        upstreamPort: rig.serverPort,
        record: true,
      );
      final caller = RpcCallerEndpoint(
        transport: await rig.member.connectTo(
          proxy.port,
          const RpcSecurityPolicy(),
        ),
      );
      await ConformanceCaller(caller).unary(probe);
      await caller.close();
      await proxy.close();
      return (
        c2s: [for (final l in proxy.links) ...l.c2s],
        s2c: [for (final l in proxy.links) ...l.s2c],
      );
    case ChannelRig():
      final pipe = Pipe(record: true);
      rig.attachServer(pipe.server);
      final caller = RpcCallerEndpoint(
        transport: RpcChannelTransport.fromChannel(
          channel: pipe.client,
          isClient: true,
        ),
      );
      await ConformanceCaller(caller).unary(probe);
      await caller.close();
      return (c2s: List.of(pipe.c2s), s2c: List.of(pipe.s2c));
    default:
      throw UnsupportedError('no raw bytes on ${rig.runtimeType}');
  }
}

/// Frames of the rpc_dart frame protocol (channel, websocket) that open
/// stream [streamId] as a request and carry garbage, plus garbage on stream
/// ids nobody opened.
List<Uint8List> framedRequest(int streamId) => [
  RpcChannelFrame.encodeMetadata(
    streamId: streamId,
    metadata: RpcMetadata.forClientRequest(conformanceService, 'unary'),
  ),
  RpcChannelFrame.encodeData(
    streamId: streamId,
    payload: RpcMessageFrame.encode(garbage(256, seed: 7)),
    endOfStream: true,
  ),
  RpcChannelFrame.encodeData(streamId: streamId + 2, payload: garbage(64)),
  RpcChannelFrame.encodeData(streamId: 0, payload: garbage(64, seed: 3)),
];

/// The frames a server would answer stream [streamId] with, carrying garbage.
List<Uint8List> framedResponse(int streamId) => [
  RpcChannelFrame.encodeMetadata(
    streamId: streamId,
    metadata: RpcMetadata.forServerInitialResponse(),
  ),
  RpcChannelFrame.encodeData(
    streamId: streamId,
    payload: RpcMessageFrame.encode(garbage(256, seed: 9)),
  ),
  RpcChannelFrame.encodeData(streamId: streamId + 2, payload: garbage(64)),
  RpcChannelFrame.encodeMetadata(
    streamId: streamId,
    metadata: RpcMetadata.forTrailer(RpcStatus.ok),
    endOfStream: true,
  ),
];

// ---------------------------------------------------------- at the server --

/// Sends [kind] to [rig]'s server from a raw client, and waits (bounded) for
/// the server to hang up. Whether it hangs up is not asserted: surviving is.
Future<void> attackServer(Rig rig, Garbage kind, Exchange? recording) async {
  switch (rig) {
    case ChannelRig():
      await _attackChannelServer(rig, kind, recording);
    case NetworkRig():
      if (kind == Garbage.framed) {
        await _framedAtServer(rig);
      } else {
        await _rawAtServer(rig.serverPort, _bytes(kind, recording?.c2s), kind);
      }
    default:
      throw UnsupportedError('${rig.runtimeType}');
  }
}

List<int> _bytes(Garbage kind, List<int>? recorded) => switch (kind) {
  Garbage.random => garbage(4096),
  Garbage.corrupted => corrupted(recorded!),
  Garbage.truncated => recorded!.sublist(0, recorded.length ~/ 2),
  Garbage.framed => throw StateError('framed is per member'),
};

Future<void> _rawAtServer(int port, List<int> bytes, Garbage kind) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final closed = Completer<void>();
  socket.listen(
    (_) {},
    onError: (Object _) {},
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
    cancelOnError: true,
  );
  socket.done.catchError((Object _) => socket).ignore();
  try {
    socket.add(bytes);
    await socket.flush();
    if (kind == Garbage.truncated) {
      socket.destroy();
      return;
    }
    await socket.close();
  } catch (_) {
    socket.destroy();
    return;
  }
  await closed.future.timeout(_wait, onTimeout: () {});
  socket.destroy();
}

Future<void> _attackChannelServer(
  ChannelRig rig,
  Garbage kind,
  Exchange? recording,
) async {
  final end = rig.rawToServer();
  final closed = Completer<void>();
  end.incoming.listen(
    (_) {},
    onDone: () {
      if (!closed.isCompleted) closed.complete();
    },
  );
  final bytes = kind == Garbage.framed
      ? [for (final f in framedRequest(1)) ...f]
      : _bytes(kind, recording?.c2s);
  await end.send(Uint8List.fromList(bytes));
  if (kind == Garbage.truncated) {
    await end.close();
    return;
  }
  await closed.future.timeout(_wait, onTimeout: () {});
  await end.close();
}

Future<void> _framedAtServer(NetworkRig rig) async {
  switch (rig.member) {
    case HttpMember():
      final body = RpcMessageFrame.encode(garbage(256, seed: 5));
      final head =
          'POST /$conformanceService/unary HTTP/1.1\r\n'
          'host: 127.0.0.1\r\n'
          'content-type: application/grpc\r\n'
          'content-length: ${body.length}\r\n\r\n';
      await _rawAtServer(rig.serverPort, [
        ...head.codeUnits,
        ...body,
      ], Garbage.framed);
    case Http2Member():
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        rig.serverPort,
      );
      socket.done.catchError((Object _) => socket).ignore();
      final conn = h2.ClientTransportConnection.viaSocket(socket);
      Future<void> request(List<int> data) async {
        final stream = conn.makeRequest([
          h2.Header.ascii(':method', 'POST'),
          h2.Header.ascii(':path', '/$conformanceService/unary'),
          h2.Header.ascii(':scheme', 'http'),
          h2.Header.ascii(':authority', '127.0.0.1'),
          h2.Header.ascii('content-type', 'application/grpc'),
          h2.Header.ascii('te', 'trailers'),
        ]);
        stream.sendData(data, endStream: true);
        await stream.incomingMessages.drain<void>().timeout(_wait);
      }

      try {
        // A gRPC prefix around garbage, and garbage with no prefix at all.
        await request(RpcMessageFrame.encode(garbage(256, seed: 5)));
        await request(garbage(300, seed: 6));
      } catch (_) {
        // A refused or reset stream is an answer.
      }
      await conn.terminate().catchError((Object _) {});
      socket.destroy();
    case WebSocketMember():
      final ws = await WebSocket.connect('ws://127.0.0.1:${rig.serverPort}');
      final closed = ws.drain<void>().catchError((Object _) {});
      for (final f in framedRequest(1)) {
        ws.add(f);
      }
      ws.add(garbage(128, seed: 4));
      await closed.timeout(_wait, onTimeout: () {});
      await ws.close().catchError((Object _) {});
    default:
      throw UnsupportedError('${rig.member}');
  }
}

// ---------------------------------------------------------- at the client --

/// Runs a unary call from a real [member] client against a fake server that
/// answers with [kind]. Returns how the call ended.
Future<Outcome> callAgainstFake(
  Member member,
  Garbage kind,
  Exchange? recording,
) async {
  switch (member) {
    case ChannelMember():
      return _channelClientAgainst(kind, recording);
    case NetworkMember():
      final stop = await _fakeServer(member, kind, recording);
      try {
        final transport = await member.connectTo(
          stop.port,
          const RpcSecurityPolicy(),
          lazy: true,
        );
        return await _oneCall(transport);
      } catch (e) {
        // Refusing the connection outright is an ending too.
        return Outcome.error(e);
      } finally {
        await stop.close();
      }
    default:
      throw UnsupportedError('$member');
  }
}

Future<Outcome> _oneCall(IRpcTransport transport) async {
  final endpoint = RpcCallerEndpoint(transport: transport);
  try {
    final call = Call.start(
      ConformanceCaller(endpoint),
      CallShape.unary,
      Blob.request(id: nextCallId()),
      deadline: const Duration(seconds: 1),
    );
    return await endsWithin(call, _wait, 'a call against a hostile server');
  } finally {
    unawaited(endpoint.close());
  }
}

Future<Outcome> _channelClientAgainst(Garbage kind, Exchange? recording) {
  final pipe = Pipe();
  pipe.server.incoming.listen((_) {
    final bytes = kind == Garbage.framed
        ? [for (final f in framedResponse(1)) ...f]
        : _bytes(kind, recording?.s2c);
    pipe.server.send(Uint8List.fromList(bytes)).then((_) {
      if (kind == Garbage.truncated) pipe.kill();
    });
  });
  return _oneCall(
    RpcChannelTransport.fromChannel(channel: pipe.client, isClient: true),
  );
}

/// Something with a port and a close.
typedef _Fake = ({int port, Future<void> Function() close});

Future<_Fake> _fakeServer(
  NetworkMember member,
  Garbage kind,
  Exchange? recording,
) async {
  if (kind != Garbage.framed) {
    final bytes = _bytes(kind, recording?.s2c);
    final fake = await FakeServer.start(
      (socket) =>
          writeThenEnd(socket, bytes, destroy: kind == Garbage.truncated),
    );
    return (port: fake.port, close: fake.close);
  }
  switch (member) {
    case HttpMember():
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 200
          ..headers.set('content-type', 'application/grpc')
          ..headers.set('grpc-status', '0')
          ..add(RpcMessageFrame.encode(garbage(256, seed: 8)));
        await request.response.close();
      }, onError: (Object _) {});
      return (port: http.port, close: () => http.close(force: true));
    case Http2Member():
      final fake = await FakeServer.start((socket) async {
        final conn = h2.ServerTransportConnection.viaSocket(socket);
        conn.incomingStreams.listen((stream) {
          stream.incomingMessages.listen((_) {}, onError: (Object _) {});
          stream.sendHeaders([
            h2.Header.ascii(':status', '200'),
            h2.Header.ascii('content-type', 'application/grpc'),
          ]);
          stream.sendData(RpcMessageFrame.encode(garbage(256, seed: 8)));
          stream.sendHeaders([
            h2.Header.ascii('grpc-status', '0'),
          ], endStream: true);
        }, onError: (Object _) {});
      }, readsItself: true);
      return (port: fake.port, close: fake.close);
    case WebSocketMember():
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        var answered = false;
        ws.listen((_) {
          if (answered) return;
          answered = true;
          for (final f in framedResponse(1)) {
            ws.add(f);
          }
          ws.add(garbage(128, seed: 2));
        }, onError: (Object _) {});
      }, onError: (Object _) {});
      return (port: http.port, close: () => http.close(force: true));
    default:
      throw UnsupportedError('$member');
  }
}
