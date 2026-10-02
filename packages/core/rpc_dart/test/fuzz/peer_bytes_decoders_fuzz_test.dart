// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every decoder rpc_dart runs on a peer's bytes, fed mutated valid encodings
// and noise from a fixed seed. A decoder may refuse input only with the types
// its callers handle; an Error, or any other exception type, is a crash
// waiting for the caller that does not expect it. The full-length harness is
// `.dart_tool/probe/fuzz_decoders.dart` (P-225); this is its gate-sized slice.

import 'dart:convert';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _iterations = 3000;

Uint8List _mutate(Random rnd, Uint8List seed) {
  var b = List<int>.from(seed);
  for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
    if (b.isEmpty) b = [rnd.nextInt(256)];
    switch (rnd.nextInt(8)) {
      case 0:
        b[rnd.nextInt(b.length)] ^= 1 << rnd.nextInt(8);
      case 1:
        b[rnd.nextInt(b.length)] = rnd.nextInt(256);
      case 2:
        const interesting = [
          0x00,
          0x7f,
          0x80,
          0xff,
          0x18,
          0x1b,
          0x1f,
          0xf8,
          0xfb,
        ];
        b[rnd.nextInt(b.length)] = interesting[rnd.nextInt(interesting.length)];
      case 3:
        b.insert(rnd.nextInt(b.length + 1), rnd.nextInt(256));
      case 4:
        b.removeAt(rnd.nextInt(b.length));
      case 5:
        b = b.sublist(0, rnd.nextInt(b.length + 1));
      case 6:
        if (b.length >= 4) {
          final i = rnd.nextInt(b.length - 3);
          const values = [0, 1, 0x7fffffff, 0xffffffff, 0x10000];
          final v = values[rnd.nextInt(values.length)];
          b
            ..[i] = (v >> 24) & 0xff
            ..[i + 1] = (v >> 16) & 0xff
            ..[i + 2] = (v >> 8) & 0xff
            ..[i + 3] = v & 0xff;
        }
      case 7:
        b.addAll(List.generate(rnd.nextInt(12), (_) => rnd.nextInt(256)));
    }
  }
  return Uint8List.fromList(b);
}

/// Runs [decode] over [_iterations] inputs and returns the exception types
/// outside [allowed], with a sample input each.
Map<String, String> _fuzz(
  List<Uint8List> seeds,
  void Function(Uint8List) decode,
  bool Function(Object) allowed, {
  int seed = 1,
}) {
  final rnd = Random(seed);
  final bad = <String, String>{};
  for (var i = 0; i < _iterations; i++) {
    final input = rnd.nextInt(10) == 0
        ? Uint8List.fromList(
            List.generate(rnd.nextInt(48), (_) => rnd.nextInt(256)),
          )
        : _mutate(rnd, seeds[rnd.nextInt(seeds.length)]);
    try {
      decode(input);
    } catch (e) {
      if (!allowed(e)) bad.putIfAbsent('${e.runtimeType}', () => '$input: $e');
    }
  }
  return bad;
}

bool _formatOnly(Object e) => e is FormatException;
bool _rpcOnly(Object e) => e is RpcException;

void main() {
  final codec = RpcCodec(RpcString.fromJson);
  final grpc = [
    RpcMessageFrame.encode(codec.serialize('x'.rpc)),
    Uint8List.fromList([
      ...RpcMessageFrame.encode(codec.serialize('a'.rpc)),
      ...RpcMessageFrame.encode(codec.serialize('bb'.rpc)),
    ]),
  ];
  final md = RpcMetadata.forClientRequest('Svc', 'method');
  final channel = [
    RpcChannelFrame.encodeMetadata(streamId: 1, metadata: md),
    RpcChannelFrame.encodeData(streamId: 3, payload: grpc[0]),
    RpcChannelFrame.encodeEndOfStream(5),
    RpcChannelFrame.encodeMetadata(
      streamId: 7,
      metadata: RpcMetadata.forTrailer(13, message: 'Ж 100%'),
    ),
  ];

  test('CBOR refuses only with FormatException', () {
    final seeds = [
      CborCodec.encode({
        'a': 1,
        'b': 'text',
        'c': [1, 2.5, true, null],
      }),
      CborCodec.encode({
        'n': {
          'x': Uint8List.fromList([1, 2]),
          'y': -5,
        },
      }),
      codec.serialize('hello'.rpc),
    ];
    expect(_fuzz(seeds, CborCodec.decode, _formatOnly), isEmpty);
    expect(_fuzz(seeds, CborCodec.decodeUnsafe, _formatOnly, seed: 2), isEmpty);
  });

  test('the gRPC parser refuses only with RpcException, at any chunking', () {
    final rnd = Random(3);
    expect(
      _fuzz(grpc, (b) {
        final parser = RpcMessageParser(maxMessageLength: 1 << 20);
        var i = 0;
        while (i < b.length) {
          final n = 1 + rnd.nextInt(b.length - i);
          parser(Uint8List.sublistView(b, i, i + n));
          i += n;
        }
      }, _rpcOnly),
      isEmpty,
    );
  });

  test('channel frames refuse only with RpcException', () {
    expect(
      _fuzz(channel, (b) {
        RpcChannelFrame.decodeAll(
          b,
          maxPayloadLen: 1 << 20,
          maxMetadataLen: 1 << 16,
          onMalformedMetadata: (_) {},
        );
      }, _rpcOnly),
      isEmpty,
    );
  });

  test('status details refuse only with FormatException', () {
    final seeds = [
      RpcStatusException(
        14,
        'retry',
        details: [RpcRetryInfo(const Duration(milliseconds: 1500))],
      ).statusDetailsBin!,
      RpcStatusException(
        3,
        'bad',
        details: [
          RpcErrorInfo(reason: 'R', metadata: {'k': 'v'}),
        ],
      ).statusDetailsBin!,
    ];
    expect(_fuzz(seeds, decodeRpcStatus, _formatOnly), isEmpty);
    expect(
      _fuzz(
        seeds,
        (b) => RpcStatusException.fromTrailer(13, 'm', detailsBin: b),
        (_) => false,
      ),
      isEmpty,
      reason: 'fromTrailer must never throw',
    );
  });

  test('header text decoders never throw', () {
    final seeds = [
      Uint8List.fromList(utf8.encode(RpcMetadata.encodeGrpcMessage('Ж 100%'))),
      Uint8List.fromList(utf8.encode('99999999H')),
    ];
    expect(
      _fuzz(seeds, (b) {
        final s = latin1.decode(b);
        RpcMetadata.decodeGrpcMessage(s);
        RpcMetadata.parseGrpcTimeout(s);
      }, (_) => false),
      isEmpty,
    );
  });
}
