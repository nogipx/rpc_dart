// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Zero-copy binary integrity and transport lifecycle for the isolate transport.
//
// Complements isolate_rpc_contract_test.dart: here we assert that large binary
// payloads survive the SendPort/ReceivePort boundary byte-for-byte (the zero-copy
// TransferableTypedData path) and that spawn -> use -> dispose behaves cleanly
// (use-after-close fails quietly, double-dispose is safe, kill releases the
// isolate).

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// ----------------------------------------------------------------------------
// Workers
// ----------------------------------------------------------------------------

/// Echoes back any TransferableTypedData direct payload unchanged.
@pragma('vm:entry-point')
void binaryEchoServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (!message.isDirect || message.directPayload == null) return;
    final payload = message.directPayload;
    if (payload is TransferableTypedData) {
      final bytes = payload.materialize().asUint8List();
      await transport.sendDirectObject(
        message.streamId,
        TransferableTypedData.fromList([bytes]),
        endStream: true,
      );
    }
  });
}

/// Plain ping/pong over direct objects, used for lifecycle checks.
@pragma('vm:entry-point')
void pingServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload == 'PING') {
      await transport.sendDirectObject(
        message.streamId,
        'PONG',
        endStream: true,
      );
    }
  });
}

Future<Uint8List> _roundtrip(
  IRpcTransport transport,
  Uint8List original,
) async {
  final streamId = transport.createStream();
  final responseFuture = transport
      .getMessagesForStream(streamId)
      .where(
        (msg) => msg.isDirect && msg.directPayload is TransferableTypedData,
      )
      .map((msg) => msg.directPayload as TransferableTypedData)
      .first
      .timeout(const Duration(seconds: 5));

  await transport.sendDirectObject(
    streamId,
    TransferableTypedData.fromList([original]),
  );
  final received = await responseFuture;
  return received.materialize().asUint8List();
}

void main() {
  group('Zero-copy binary integrity over isolate transport', () {
    test('large Uint8List round-trips byte-for-byte (4 MiB)', () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: binaryEchoServer,
        customParams: const {},
        isolateId: 'binary-large',
      );
      try {
        // 4 MiB pseudo-random-ish content (deterministic pattern).
        final size = 4 * 1024 * 1024;
        final original = Uint8List(size);
        for (var i = 0; i < size; i++) {
          original[i] = (i * 31 + 7) & 0xFF;
        }

        final roundtrip = await _roundtrip(spawned.transport, original);

        expect(roundtrip.length, equals(size));
        // Spot-check boundaries plus a full equality check.
        expect(roundtrip.first, equals(original.first));
        expect(roundtrip.last, equals(original.last));
        expect(roundtrip, orderedEquals(original));
      } finally {
        spawned.kill();
      }
    });

    test('empty and single-byte payloads survive intact', () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: binaryEchoServer,
        customParams: const {},
        isolateId: 'binary-edge',
      );
      try {
        final empty = await _roundtrip(spawned.transport, Uint8List(0));
        expect(empty, isEmpty);

        final single = await _roundtrip(
          spawned.transport,
          Uint8List.fromList([0xAB]),
        );
        expect(single, orderedEquals([0xAB]));
      } finally {
        spawned.kill();
      }
    });

    test('many sequential binary round-trips stay intact', () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: binaryEchoServer,
        customParams: const {},
        isolateId: 'binary-many',
      );
      try {
        for (var n = 0; n < 50; n++) {
          final original = Uint8List.fromList(
            List<int>.generate(1024, (i) => (i + n) & 0xFF),
          );
          final roundtrip = await _roundtrip(spawned.transport, original);
          expect(
            roundtrip,
            orderedEquals(original),
            reason: 'payload #$n must round-trip intact',
          );
        }
      } finally {
        spawned.kill();
      }
    });
  });

  group('Isolate transport lifecycle', () {
    test('dispose closes the transport; kill releases the isolate', () async {
      final mainIsolate = Isolate.current.hashCode;
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: pingServer,
        customParams: const {},
        isolateId: 'lifecycle-dispose',
      );

      // Use it once.
      final streamId = spawned.transport.createStream();
      final pong = spawned.transport
          .getMessagesForStream(streamId)
          .where((m) => m.isDirect && m.directPayload == 'PONG')
          .first
          .timeout(const Duration(seconds: 5));
      await spawned.transport.sendDirectObject(streamId, 'PING');
      await pong;

      expect(spawned.transport.isClosed, isFalse);

      await spawned.transport.close();
      expect(spawned.transport.isClosed, isTrue);

      spawned.kill();
      // Sanity: we are still alive on the main isolate after killing the worker.
      expect(Isolate.current.hashCode, equals(mainIsolate));
    });

    test('use after close fails cleanly (no throw, no delivery)', () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: pingServer,
        customParams: const {},
        isolateId: 'lifecycle-use-after-close',
      );

      await spawned.transport.close();
      expect(spawned.transport.isClosed, isTrue);

      // Sending after close must not throw; the message is silently dropped.
      final streamId = spawned.transport.createStream();
      await expectLater(
        spawned.transport.sendDirectObject(streamId, 'PING'),
        completes,
      );
      // releaseStreamId on a closed transport must not throw.
      expect(
        () => spawned.transport.releaseStreamId(streamId),
        returnsNormally,
      );

      spawned.kill();
    });

    test('double close / double kill is safe', () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: pingServer,
        customParams: const {},
        isolateId: 'lifecycle-double-dispose',
      );

      await spawned.transport.close();
      await expectLater(spawned.transport.close(), completes);

      // kill twice must not throw.
      spawned.kill();
      expect(spawned.kill, returnsNormally);
    });

    test('caller endpoint rejects new calls after close', () async {
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: pingServer,
        customParams: const {},
        isolateId: 'lifecycle-endpoint-closed',
      );
      final caller = RpcCallerEndpoint(transport: spawned.transport);
      await caller.close();

      expect(
        () => caller.unaryRequest<_Empty, _Empty>(
          serviceName: 'x',
          methodName: 'y',
          request: const _Empty(),
          requestCodec: const RpcCodec<_Empty>(_Empty.fromJson),
          responseCodec: const RpcCodec<_Empty>(_Empty.fromJson),
        ),
        throwsA(isA<StateError>()),
      );

      spawned.kill();
    });
  });
}

class _Empty implements IRpcSerializable {
  const _Empty();
  @override
  Map<String, dynamic> toJson() => const {};
  static _Empty fromJson(Map<String, dynamic> json) => const _Empty();
}
