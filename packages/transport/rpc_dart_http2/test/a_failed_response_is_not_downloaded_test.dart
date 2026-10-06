// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response the caller has already failed -- a non-200, a 200 that is not
// gRPC, headers our policy refuses, a body that does not parse -- is reset, so
// the rest of its body is neither downloaded nor fed to the parser frame by
// frame. An interim 1xx is not a final answer and must not fail the call.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _chunk = 16 * 1024;
const _chunks = 64;

final class _Capture extends LogOutput {
  final records = <LogEvent>[];
  @override
  void write(LogRecord record) {
    if (record is LogEvent) records.add(record);
  }
}

/// What the peer saw of the one stream it answered.
final class _Served {
  var sent = 0;
  final reset = Completer<void>();
  final finished = Completer<void>();
}

Future<void> _requestEnd(http2.ServerTransportStream stream) async {
  await for (final m in stream.incomingMessages) {
    if (m.endStream) break;
  }
}

/// A peer answering [headers] and then 1 MiB of `<`, which is not a gRPC frame.
Future<ServerSocket> _peer(
  List<http2.Header> headers,
  List<_Served> served,
) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) async {
      final s = _Served();
      served.add(s);
      stream.onTerminated = (_) {
        if (!s.reset.isCompleted) s.reset.complete();
      };
      await _requestEnd(stream);
      stream.sendHeaders(headers);
      final chunk = Uint8List.fromList(List.filled(_chunk, 0x3C));
      for (var i = 0; i < _chunks && !s.reset.isCompleted; i++) {
        try {
          stream.sendData(chunk, endStream: i == _chunks - 1);
          s.sent += _chunk;
        } catch (_) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      s.finished.complete();
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

http2.Header _h(String name, String value) => http2.Header.ascii(name, value);

void main() {
  final arms = [
    (
      name: 'an HTML 503',
      headers: [_h(':status', '503'), _h('content-type', 'text/html')],
      events: ['status 14'],
      parsed: false,
    ),
    (
      name: 'an HTML 200',
      headers: [_h(':status', '200'), _h('content-type', 'text/html')],
      events: ['status 13'],
      parsed: false,
    ),
    (
      name: 'headers the policy refuses',
      headers: [
        _h(':status', '200'),
        _h('content-type', 'application/grpc'),
        _h('x-big', 'v' * (9 * 1024)),
      ],
      events: ['error'],
      parsed: false,
    ),
    (
      name: 'a body that does not parse',
      headers: [_h(':status', '200'), _h('content-type', 'application/grpc')],
      events: ['headers', 'error'],
      parsed: true,
    ),
  ];

  for (final arm in arms) {
    test('${arm.name} is reset, not downloaded frame by frame', () async {
      final served = <_Served>[];
      final peer = await _peer(arm.headers, served);
      final capture = _Capture();
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: peer.port,
        logger: LogScope(
          LogController(outputs: [capture], minLevel: RpcLogLevel.warning),
          'test',
        ),
      );
      addTearDown(() async {
        await transport.close();
        await peer.close();
      });

      // Driven below the endpoint: the endpoint releases the id when the call
      // ends, which would reset the stream for us and hide a missing reset.
      final id = transport.createStream();
      final events = <String>[];
      final done = Completer<void>();
      transport
          .getMessagesForStream(id)
          .listen(
            (m) {
              final status = m.metadata?.getHeaderValue('grpc-status');
              events.add(status != null ? 'status $status' : 'headers');
            },
            onError: (Object _) => events.add('error'),
            onDone: done.complete,
          );
      await transport.sendMetadata(id, RpcMetadata.forClientRequest('S', 'M'));
      await transport.finishSending(id);
      await done.future.timeout(const Duration(seconds: 5));

      expect(events, arm.events);
      await served.single.finished.future.timeout(const Duration(seconds: 5));
      expect(
        served.single.reset.isCompleted,
        isTrue,
        reason: 'the peer must see RST_STREAM once the call has failed',
      );
      expect(served.single.sent, lessThan(_chunk * _chunks));
      // The one parse failure is logged by the parser and by the transport.
      expect(
        capture.records.where((r) => r.level == RpcLogLevel.error),
        hasLength(lessThanOrEqualTo(arm.parsed ? 2 : 1)),
      );
    });
  }

  test('an interim 103 before the answer does not fail the call', () async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      conn.incomingStreams.listen((stream) async {
        await _requestEnd(stream);
        stream.sendHeaders([_h(':status', '103')]);
        stream.sendHeaders([
          _h(':status', '200'),
          _h('content-type', 'application/grpc'),
        ]);
        stream.sendData(
          RpcMessageFrame.encode(_codec.serialize('ok'.rpc), compressed: false),
        );
        stream.sendHeaders([_h('grpc-status', '0')], endStream: true);
      }, onError: (Object _) {});
    }, onError: (Object _) {});
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
    );
    addTearDown(() async {
      await transport.close();
      await socket.close();
    });

    final response = await RpcCallerEndpoint(transport: transport)
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'S',
          methodName: 'M',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    expect(response.value, 'ok');
  });
}
