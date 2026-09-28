// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `guest_to_host_order_test.dart` asks whether frames the GUEST produces arrive
// in order. This is the other direction, which nothing asked.
//
// It matters on Android because the host->guest forward has TWO paths with
// different latencies. At or above `NAMED_DATA_THRESHOLD` (64 KiB) the bytes go
// through `provideNamedData` and an async JS IIFE that AWAITS
// `consumeNamedDataAsArrayBuffer`; below it they go through a synchronous
// `_rpcWasmReceiveBytesB64`. So a small frame submitted after a large one can
// reach the guest first — and the guest's channel reassembles a byte STREAM, so
// a frame delivered out of order is not a reordered message, it is a 9-byte
// header read from the middle of somebody else's payload.
//
// iOS has the same two-path shape (a URL-scheme fetch per frame) and is
// included for the same reason the guest->host test is platform-agnostic: the
// witness should fail wherever the ordering stops holding.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

/// Counts how many host->guest forwards are in flight AT ONCE.
///
/// Without this the test cannot tell "the ordering holds" from "the two forward
/// paths never overlapped", and those are opposite conclusions. Nothing in the
/// library serialises here — neither `RpcFrameMultiplexedChannel.send` nor
/// `RpcFlutterWasmBridge.send` holds a lock — so the number is the bench's own
/// precondition, not a property of the code under test.
final class _CountingBridge implements RpcWasmBridge {
  _CountingBridge(this._inner);

  final RpcWasmBridge _inner;
  int inFlight = 0;
  int peakInFlight = 0;

  /// The size of every frame that overlapped another, so the arm can say
  /// whether a LARGE one ever did.
  final List<int> overlappedSizes = [];

  @override
  Stream<Uint8List> get incoming => _inner.incoming;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> send(Uint8List data) async {
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    if (inFlight > 1) overlappedSizes.add(data.length);
    try {
      await _inner.send(data);
    } finally {
      inFlight--;
    }
  }
}

/// Comfortably over the 64 KiB threshold, so the framed message takes the
/// named-data path with no argument about the prefix.
const _bigBytes = 192 * 1024;

/// Enough small frames to interleave with a large one's await.
const _smallCount = 50;

/// Several large frames per burst, so more than one interleaving is tried.
const _bigCount = 5;

/// And the whole burst repeated: a race that needs a particular interleaving is
/// not refuted by one chance at it.
const _bursts = 3;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a large host->guest frame is not overtaken by small ones',
    (_) async {
      final wasm = (await rootBundle.load(
        'assets/guest.wasm',
      )).buffer.asUint8List();
      final mjs = await rootBundle.loadString('assets/guest.mjs');
      final bridge = await RpcFlutterWasmBridge.load(
        wasmBytes: wasm,
        mjsCode: mjs,
      ).timeout(const Duration(seconds: 60));
      final counting = _CountingBridge(bridge);
      final caller = RpcCallerEndpoint(
        transport: RpcWasmTransport.fromBridge(
          bridge: counting,
          isClient: true,
        ),
      );

      Future<String> say(String payload) => caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Say',
            request: payload.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then((r) => r.value);

      // The large requests and the small ones are issued in ONE turn, so the
      // plugin sees them concurrently — which is the only way the two forward
      // paths can overlap. SEVERAL large ones, and the whole burst repeated:
      // one large frame among fifty is a single chance per run, and a race that
      // needs a particular interleaving is not refuted by one chance.
      final big = 'B' * _bigBytes;
      final clock = Stopwatch()..start();
      late List<String> results;
      for (var round = 0; round < _bursts; round++) {
        results = await Future.wait([
          for (var b = 0; b < _bigCount; b++) say(big),
          for (var i = 0; i < _smallCount; i++) say('small-$i'),
        ]).timeout(const Duration(minutes: 2));
        for (var b = 0; b < _bigCount; b++) {
          expect(
            results[b],
            'echo:$big',
            reason:
                'burst $round: a large frame was overtaken, so the guest '
                'reassembled its header from the middle of another frame',
          );
        }
        for (var i = 0; i < _smallCount; i++) {
          expect(results[_bigCount + i], 'echo:small-$i');
        }
      }

      final bigOverlaps = counting.overlappedSizes
          .where((n) => n >= 64 * 1024)
          .length;
      // ignore: avoid_print
      print(
        'platform: ${Platform.operatingSystem}  '
        'big: $_bigBytes B  small: $_smallCount  '
        'elapsed: ${clock.elapsedMilliseconds}ms  '
        'peak forwards in flight: ${counting.peakInFlight}  '
        'overlapped frames: ${counting.overlappedSizes.length} '
        '(>=64 KiB: $bigOverlaps)',
      );

      // The bench's OWN precondition. Without an overlap the arm proves nothing
      // about ordering, so say so here rather than reporting a pass.
      expect(
        counting.peakInFlight,
        greaterThan(1),
        reason:
            'no two forwards were ever in flight together, so this run could '
            'not have observed a reorder either way',
      );

      // Every answer belongs to its own request, asserted per burst above. A
      // reorder on the byte stream shows up as a framing failure (the call
      // errors), a mismatched echo, or a hang — all three fail there.
      expect(results, hasLength(_bigCount + _smallCount));

      // GUARD: the connection is still usable afterwards. A corrupted byte
      // stream that happened to parse would leave the channel wrong rather
      // than failing the calls above.
      expect(await say('after'), 'echo:after');

      await caller.close();
      await bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
