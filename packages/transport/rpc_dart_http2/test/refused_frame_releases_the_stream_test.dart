// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _answerFramingViolation answers a peer whose DATA frame the parser refused.
// Its sibling 200 lines up, _answerRejectedStream, releases the stream in a
// `finally` after answering, because a refusal is the last thing that stream
// will ever carry. This one did not -- so whether the server reclaimed the
// stream depended on the PEER setting END_STREAM, which is the peer's choice.
//
// A hostile request costs five bytes: valid headers, then a gRPC prefix
// declaring 32 MiB, and no half-close. The parser rejects on the prefix, the
// server answers RESOURCE_EXHAUSTED -- and then held the stream, its inbound
// subscription, its parser and its outgoing pump for the life of the
// connection. Measured over 200 such requests on one connection, read from the
// server's own health() while it was still open:
//
//   before: incoming=200 subs=200 parsers=200 pumps=200  (peer saw grpc-status 8)
//   after : incoming=0   subs=0   parsers=0   pumps=0    (peer saw grpc-status 8)
//
// A handler already running on the id had the same problem one layer up: the
// parse error reaches its request stream, but nothing CLOSES that stream, so an
// upload handler stayed in its `await for` -- 1 responder still live 600 ms
// after the refusal, with or without the release. The synthesized cancellation
// _fcRefuseOverrun already sends for exactly this reason is what ends it.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A gRPC prefix declaring 32 MiB against the 16 MiB default limit. The parser
/// refuses on the PREFIX, so the whole hostile request is these five bytes.
final _oversizedPrefix = Uint8List.fromList([0, 0x02, 0x00, 0x00, 0x00]);

Uint8List get _goodBody =>
    RpcMessageFrame.encode(_codec.serialize('x'.rpc), compressed: false);

/// Set by the upload handler to the number of messages it has taken.
int _uploaded = 0;

/// Completes the first time the upload handler's request stream ends.
late Completer<void> _uploadEnded;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      handler: (requests, {RpcContext? context}) async {
        try {
          await for (final _ in requests) {
            _uploaded++;
          }
        } finally {
          if (!_uploadEnded.isCompleted) _uploadEnded.complete();
        }
        return 'got-$_uploaded'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

List<http2.Header> _headers(int port, String path) => [
  http2.Header.ascii(':method', 'POST'),
  http2.Header.ascii(':path', path),
  http2.Header.ascii(':scheme', 'http'),
  http2.Header.ascii(':authority', '127.0.0.1:$port'),
  http2.Header.ascii('content-type', 'application/grpc+proto'),
  http2.Header.ascii('te', 'trailers'),
];

/// One live peer connection, so the server's counters can be read while it is
/// still OPEN. Reading them after a terminate measures the transport's own
/// close(), which clears every map and makes any arm look clean.
final class _Peer {
  _Peer(this._socket, this._conn, this.port);

  final Socket _socket;
  final http2.ClientTransportConnection _conn;
  final int port;

  static Future<_Peer> connect(int port) async {
    final socket = await Socket.connect('127.0.0.1', port);
    return _Peer(
      socket,
      http2.ClientTransportConnection.viaSocket(socket),
      port,
    );
  }

  /// Opens [count] streams, sends [body] on each, and waits for the answers.
  ///
  /// [halfClose] is the whole experiment when [body] is refused: an ordinary
  /// client sets END_STREAM on its last DATA frame, a hostile one does not.
  Future<Map<String, String>> ask(
    Uint8List body, {
    int count = 1,
    bool halfClose = false,
    String path = '/Svc/Echo',
  }) async {
    var lastHeaders = <String, String>{};
    final waits = <Future<void>>[];

    for (var i = 0; i < count; i++) {
      final stream = _conn.makeRequest(_headers(port, path));
      stream.sendData(body, endStream: halfClose);
      waits.add(
        stream.incomingMessages
            .forEach((message) {
              if (message is http2.HeadersStreamMessage) {
                final headers = <String, String>{};
                for (final h in message.headers) {
                  headers[String.fromCharCodes(h.name)] = String.fromCharCodes(
                    h.value,
                  );
                }
                lastHeaders = headers;
              }
            })
            .timeout(const Duration(seconds: 6))
            // A stream nobody answers never completes; count it rather than
            // failing the whole run.
            .catchError((Object _) {}),
      );
    }

    await Future.wait(waits);
    return lastHeaders;
  }

  /// Opens one stream and returns it, so a test can feed it over time.
  http2.ClientTransportStream open(String path) {
    final stream = _conn.makeRequest(_headers(port, path));
    unawaited(stream.incomingMessages.drain<void>().catchError((Object _) {}));
    return stream;
  }

  Future<void> close() async {
    await _conn.terminate();
    _socket.destroy();
  }
}

void main() {
  late RpcHttp2Server server;
  RpcResponderEndpoint? endpoint;

  setUp(() async {
    _uploaded = 0;
    _uploadEnded = Completer<void>();
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) {
        endpoint = e;
        e.registerServiceContract(_Contract());
      },
    );
    await server.start();
  });

  tearDown(() => server.stop());

  Future<Map<String, Object?>> counts() async {
    final details = (await endpoint!.transport.health()).details;
    return {
      'incomingStreams': details['incomingStreams'],
      'streamSubscriptions': details['streamSubscriptions'],
      'streamParsers': details['streamParsers'],
      'outgoingPumps': details['outgoingPumps'],
    };
  }

  // WITNESS: every one of these read 20 before the release was added.
  test('a refused frame releases the stream even with no half-close', () async {
    final peer = await _Peer.connect(server.port);
    final headers = await peer.ask(_oversizedPrefix, count: 20);

    expect(
      headers['grpc-status'],
      RpcStatus.resourceExhausted.toString(),
      reason: 'the arm has to reach the refusal it names',
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      await counts(),
      {
        'incomingStreams': 0,
        'streamSubscriptions': 0,
        'streamParsers': 0,
        'outgoingPumps': 0,
      },
      reason:
          'the server answered all 20 and then kept their state, because the '
          'peer never set END_STREAM -- five bytes each to pin a slot',
    );

    await peer.close();
  });

  // WITNESS: this responder stayed live in its `await for` forever.
  test('a refused frame ends a handler already running on the id', () async {
    final peer = await _Peer.connect(server.port);
    final stream = peer.open('/Svc/Collect');

    stream.sendData(_goodBody);
    stream.sendData(_goodBody);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      _uploaded,
      2,
      reason: 'the handler must be running before the frame',
    );

    stream.sendData(_oversizedPrefix);

    await expectLater(
      _uploadEnded.future.timeout(const Duration(seconds: 5)),
      completes,
      reason: 'the upload handler was left waiting on a stream nobody closes',
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(endpoint!.collectEndpointMetrics()['activeResponders'], 0);
    expect(await counts(), {
      'incomingStreams': 0,
      'streamSubscriptions': 0,
      'streamParsers': 0,
      'outgoingPumps': 0,
    });

    await peer.close();
  });

  // GUARD: passes on both sides. The ordinary client shape was already clean,
  // and the refusal it gets must not change.
  test('a refused frame WITH a half-close is unchanged', () async {
    final peer = await _Peer.connect(server.port);
    final headers = await peer.ask(
      _oversizedPrefix,
      count: 20,
      halfClose: true,
    );

    expect(headers['grpc-status'], RpcStatus.resourceExhausted.toString());

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await counts(), {
      'incomingStreams': 0,
      'streamSubscriptions': 0,
      'streamParsers': 0,
      'outgoingPumps': 0,
    });

    await peer.close();
  });

  // GUARD: releasing from inside the transport must not break the served path.
  test('the connection still serves after a refusal', () async {
    final peer = await _Peer.connect(server.port);
    await peer.ask(_oversizedPrefix, count: 5);

    final ok = await peer.ask(_goodBody, halfClose: true);
    expect(
      ok['grpc-status'],
      '0',
      reason: 'refusing one frame must not poison the connection',
    );

    await peer.close();
  });
}
