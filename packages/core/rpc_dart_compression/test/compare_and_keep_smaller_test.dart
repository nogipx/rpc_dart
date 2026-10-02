// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Compression is compare-and-keep-smaller: each message is compressed and the
// result kept only when it is smaller. Core asserts that against the VM's dart:io
// gzip; this asserts it against `RpcGzipCodec`, the codec that also exists on the
// web, on every platform this suite runs on. The property is a RATIO, and ratios
// do not travel between implementations.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => req,
    );
  }
}

/// Records the size of each DATA frame written into it.
final class _Side implements IRpcChannel {
  final _ctl = StreamController<Uint8List>();
  late _Side peer;
  final dataSizes = <int>[];

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {
    final view = ByteData.sublistView(data);
    final len = view.getUint32(5);
    if ((view.getUint8(4) & RpcChannelFrame.flagMetadata) == 0 && len > 0) {
      dataSizes.add(len);
    }
    if (!peer._ctl.isClosed) peer._ctl.add(data);
  }

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }
}

/// Deterministic, structureless text — the case where gzip can only add overhead.
String _incompressible(int n) {
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
  final buf = StringBuffer();
  var x = 0x2545F491;
  for (var i = 0; i < n; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    buf.writeCharCode(alphabet.codeUnitAt(x % alphabet.length));
  }
  return buf.toString();
}

/// Sends [text] and returns the request DATA frame size, asserting it round-trips.
Future<int> _frameSize(String text, {required bool compress}) async {
  final client = _Side();
  final server = _Side();
  client.peer = server;
  server.peer = client;

  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(
        channel: client,
        closeOnOversizedFrame: false,
      ),
      isClient: true,
    ),
    compressionEnabled: compress,
  );
  final responder =
      RpcResponderEndpoint(
          transport: RpcChannelTransport(
            channel: RpcFrameMultiplexedChannel(channel: server),
            isClient: false,
          ),
        )
        ..registerServiceContract(_Echo())
        ..start();
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  Future<String> call() async {
    final r = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'echo',
      request: text.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return r.value;
  }

  await call();
  client.dataSizes.clear();
  final echoed = await call();
  expect(echoed, text, reason: 'the payload must round-trip unchanged');
  return client.dataSizes.first;
}

void main() {
  setUpAll(RpcGzipCodec.register);

  group('WITNESS: with RpcGzipCodec, compression never makes a message '
      'bigger', () {
    for (final size in [32, 64, 128, 192]) {
      test('$size incompressible bytes', () async {
        final text = _incompressible(size);
        final off = await _frameSize(text, compress: false);
        final on = await _frameSize(text, compress: true);
        // The row the record quotes.
        print('RpcGzipCodec  $size B incompressible: off $off, on $on');
        expect(on, lessThanOrEqualTo(off));
      });
    }
  });

  group('GUARD: real savings are still taken', () {
    test('a large incompressible message is still compressed', () async {
      final text = _incompressible(4096);
      final off = await _frameSize(text, compress: false);
      final on = await _frameSize(text, compress: true);
      print('RpcGzipCodec  4096 B incompressible: off $off, on $on');
      expect(on, lessThan(off));
    });

    test('a SMALL compressible message is still compressed', () async {
      final text = 'a' * 32;
      final off = await _frameSize(text, compress: false);
      final on = await _frameSize(text, compress: true);
      print('RpcGzipCodec  32 B compressible: off $off, on $on');
      expect(on, lessThan(off));
    });
  });
}
