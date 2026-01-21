// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Simple compile-check entrypoint for dart2wasm/dart2js.
// Instantiates the transport with an in-memory WebSocketChannel.fromStream,
// which avoids dart:io dependencies.
import 'dart:async';

import 'package:async/async.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() async {
  final channel = _DummyWebSocketChannel();

  final transport = RpcWebSocketCallerTransport(
    channel,
    logger: RpcLogger('compile-check'),
  );

  // Minimal interaction: create/release a stream ID and close.
  final streamId = transport.createStream();
  await transport.sendMetadata(
    streamId,
    const RpcMetadata([]),
    endStream: true,
  );
  await transport.close();
}

class _DummyWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  final _controller = StreamChannelController<Object?>(sync: true);

  @override
  WebSocketSink get sink => _DummySink(_controller.local.sink);

  @override
  Stream get stream => _controller.foreign.stream;

  @override
  Future<void> get ready async {}

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _DummySink extends DelegatingStreamSink implements WebSocketSink {
  _DummySink(super.sink);

  @override
  Future close([int? closeCode, String? closeReason]) => super.close();
}
