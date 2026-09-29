// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Compression was applied to every message whenever it was enabled, so gzip's
// fixed overhead made small incompressible payloads LARGER on the wire than
// sending them plain.
//
// The frame carries a per-message compression flag, so declaring
// `grpc-encoding: gzip` and sending an individual message uncompressed is ordinary
// gRPC — which is what lets the encoder compress and keep the result only when it
// is smaller.
//
// That is deliberately NOT a size threshold. A threshold would also throw away the
// saving on small COMPRESSIBLE payloads, which is real and is what the last guard
// here pins.
//
// The measurements are in `.claude/loop/rounds/513`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
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

  await call(); // connection setup is not per-call cost
  client.dataSizes.clear();
  final echoed = await call();

  // Whatever the encoder decided, the bytes must survive it.
  expect(echoed, text, reason: 'the payload must round-trip unchanged');
  return client.dataSizes.first;
}

void main() {
  group('WITNESS: enabling compression never makes a message bigger', () {
    for (final size in [32, 64, 128, 192]) {
      test('$size incompressible bytes', () async {
        final text = _incompressible(size);
        final off = await _frameSize(text, compress: false);
        final on = await _frameSize(text, compress: true);

        expect(
          on,
          lessThanOrEqualTo(off),
          reason:
              'gzip adds a fixed ~20 bytes, so compressing unconditionally sent '
              'MORE bytes than not compressing at all',
        );
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  group('GUARD: real savings are still taken', () {
    test(
      'a large incompressible message is still compressed',
      () async {
        final text = _incompressible(4096);
        final off = await _frameSize(text, compress: false);
        final on = await _frameSize(text, compress: true);

        expect(
          on,
          lessThan(off),
          reason: 'refusing to compress anything would also pass the witness',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a SMALL compressible message is still compressed',
      () async {
        // The arm that distinguishes compare-and-keep-smaller from a size
        // threshold. A 256-byte threshold would send this one plain and lose a
        // real saving; comparing keeps it.
        final text = 'a' * 32;
        final off = await _frameSize(text, compress: false);
        final on = await _frameSize(text, compress: true);

        expect(
          on,
          lessThan(off),
          reason:
              'gzip beats plain even at 32 bytes when the bytes repeat, and a size '
              'threshold would have thrown that away',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'compression disabled sends exactly the plain bytes',
      () async {
        final text = _incompressible(4096);
        expect(await _frameSize(text, compress: false), greaterThan(4096));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
