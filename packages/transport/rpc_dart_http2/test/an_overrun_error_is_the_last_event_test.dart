// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The un-consumed window fails a call with RESOURCE_EXHAUSTED. That error is
// the call's last event: the message that overran the window, and anything
// still queued for the stream, is not delivered behind it.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  test('nothing is delivered after the overrun error', () async {
    const window = 16 * 1024;
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      conn.incomingStreams.listen((stream) async {
        stream.onTerminated = (_) {};
        await for (final m in stream.incomingMessages) {
          if (m.endStream) break;
        }
        stream.sendHeaders([
          http2.Header.ascii(':status', '200'),
          http2.Header.ascii('content-type', 'application/grpc'),
        ]);
        for (var i = 0; i < 8; i++) {
          try {
            stream.sendData(
              RpcMessageFrame.encode(Uint8List(4 * 1024), compressed: false),
            );
          } catch (_) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }, onError: (Object _) {});
    }, onError: (Object _) {});
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: socket.port,
      policy: const RpcSecurityPolicy(flowControlWindowBytes: window),
    );
    addTearDown(() async {
      await transport.close();
      await socket.close();
    });

    final id = transport.createStream();
    final events = <String>[];
    final done = Completer<void>();
    final subscription = transport
        .getMessagesForStream(id)
        .listen(
          (m) => events.add(m.payload != null ? 'data' : 'headers'),
          onError: (Object e) => events.add(
            e is RpcStatusException &&
                    e.statusCode == RpcStatus.resourceExhausted
                ? 'overrun'
                : 'error $e',
          ),
          onDone: done.complete,
        );
    // A consumer that stops reading is what overruns the window.
    subscription.pause();
    await transport.sendMetadata(id, RpcMetadata.forClientRequest('S', 'M'));
    await transport.finishSending(id);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    subscription.resume();
    await done.future.timeout(const Duration(seconds: 5));

    expect(events, contains('overrun'));
    expect(
      events.last,
      'overrun',
      reason: 'the overrunning message must not arrive after the error',
    );
  });

  test('no request payload reaches the handler after the overrun', () async {
    const window = 16 * 1024;
    final events = <String>[];
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((client) {
      final responder = RpcHttp2ResponderTransport(
        connection: http2.ServerTransportConnection.viaSocket(client),
        policy: const RpcSecurityPolicy(flowControlWindowBytes: window),
      );
      var opened = false;
      responder.incomingMessages.listen((m) {
        if (opened) return;
        opened = true;
        final subscription = responder.getMessagesForStream(m.streamId).listen((
          m,
        ) {
          if (m.metadata?.getHeaderValue(RpcHeaders.xClientCancelled) != null) {
            events.add('cancel');
          } else if (m.payload != null) {
            events.add('data');
          }
        }, onError: (Object _) {});
        // A handler that stops reading is what overruns the window.
        subscription.pause();
        Future<void>.delayed(
          const Duration(milliseconds: 500),
          subscription.resume,
        );
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

    final id = transport.createStream();
    await transport.sendMetadata(id, RpcMetadata.forClientRequest('S', 'M'));
    for (var i = 0; i < 8; i++) {
      try {
        await transport.sendMessage(
          id,
          RpcMessageFrame.encode(Uint8List(4 * 1024), compressed: false),
        );
      } catch (_) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final cancelAt = events.indexOf('cancel');
    expect(cancelAt, isNonNegative, reason: 'the window must be overrun');
    expect(
      events.sublist(cancelAt),
      isNot(contains('data')),
      reason: 'the overrunning payload must not follow the cancellation',
    );
  });
}
