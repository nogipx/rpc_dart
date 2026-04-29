// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared message types
// ---------------------------------------------------------------------------

class PeerRequest implements IRpcSerializable {
  final String text;
  PeerRequest(this.text);

  factory PeerRequest.fromJson(Map<String, dynamic> json) =>
      PeerRequest(json['text'] as String);

  @override
  Map<String, dynamic> toJson() => {'text': text};
}

class PeerResponse implements IRpcSerializable {
  final String text;
  PeerResponse(this.text);

  factory PeerResponse.fromJson(Map<String, dynamic> json) =>
      PeerResponse(json['text'] as String);

  @override
  Map<String, dynamic> toJson() => {'text': text};
}

final _requestCodec = RpcCodec<PeerRequest>(PeerRequest.fromJson);
final _responseCodec = RpcCodec<PeerResponse>(PeerResponse.fromJson);

// ---------------------------------------------------------------------------
// RpcPeerContract implementation — ChatService
//
// Both peers host the same service name but opposite instances.
// Each side registers handlers (incoming) and calls the other side (outgoing).
// ---------------------------------------------------------------------------

final class ChatContract extends RpcPeerContract {
  final String _prefix; // 'A' or 'B' — marks responses from this peer
  final List<String> log = [];

  ChatContract(RpcPeerEndpoint endpoint, this._prefix)
      : super('ChatService', endpoint);

  @override
  void setup() {
    addUnaryMethod<PeerRequest, PeerResponse>(
      methodName: 'Echo',
      handler: (req, {context}) async {
        log.add('Echo:${req.text}');
        return PeerResponse('$_prefix:${req.text}');
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addServerStreamMethod<PeerRequest, PeerResponse>(
      methodName: 'Stream',
      handler: (req, {context}) async* {
        for (var i = 1; i <= 3; i++) {
          yield PeerResponse('$_prefix:$i:${req.text}');
          await Future.delayed(Duration(milliseconds: 1));
        }
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addClientStreamMethod<PeerRequest, PeerResponse>(
      methodName: 'Collect',
      handler: (requests, {context}) async {
        final parts = <String>[];
        await for (final r in requests) {
          parts.add(r.text);
        }
        return PeerResponse('$_prefix:${parts.join(',')}');
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );

    addBidirectionalMethod<PeerRequest, PeerResponse>(
      methodName: 'Mirror',
      handler: (requests, {context}) async* {
        await for (final r in requests) {
          yield PeerResponse('$_prefix:${r.text}');
          await Future.delayed(Duration(milliseconds: 1));
        }
      },
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
    );
  }

  // Outgoing call helpers — delegated via RpcPeerContract.callXxx

  Future<PeerResponse> echo(String text) => callUnary(
        methodName: 'Echo',
        request: PeerRequest(text),
        requestCodec: _requestCodec,
        responseCodec: _responseCodec,
      );

  Stream<PeerResponse> stream(String text) => callServerStream(
        methodName: 'Stream',
        request: PeerRequest(text),
        requestCodec: _requestCodec,
        responseCodec: _responseCodec,
      );

  Future<PeerResponse> collect(List<String> texts) => callClientStream(
        methodName: 'Collect',
        requests: Stream.fromIterable(texts.map(PeerRequest.new)),
        requestCodec: _requestCodec,
        responseCodec: _responseCodec,
      );

  Stream<PeerResponse> mirror(Stream<String> texts) => callBidirectionalStream(
        methodName: 'Mirror',
        requests: texts.map(PeerRequest.new),
        requestCodec: _requestCodec,
        responseCodec: _responseCodec,
      );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late RpcPeerEndpoint peerA;
  late RpcPeerEndpoint peerB;
  late ChatContract contractA; // hosted on peerA, calls peerB
  late ChatContract contractB; // hosted on peerB, calls peerA

  setUp(() {
    final (transportA, transportB) = RpcInMemoryTransport.pair();

    peerA = RpcPeerEndpoint(transport: transportA, debugLabel: 'peerA');
    peerB = RpcPeerEndpoint(transport: transportB, debugLabel: 'peerB');

    // contractA is registered on peerA and makes calls to peerB
    contractA = ChatContract(peerA, 'A');
    peerA.registerServiceContract(contractA);
    peerA.start();

    // contractB is registered on peerB and makes calls to peerA
    contractB = ChatContract(peerB, 'B');
    peerB.registerServiceContract(contractB);
    peerB.start();
  });

  tearDown(() async {
    await peerA.close();
    await peerB.close();
    contractA.log.clear();
    contractB.log.clear();
  });

  // -------------------------------------------------------------------------
  group('contractA calls peerB (handled by contractB)', () {
    test('unary', () async {
      final resp = await contractA.echo('hello');
      expect(resp.text, 'B:hello');
      expect(contractB.log, contains('Echo:hello'));
    });

    test('server stream', () async {
      final items =
          await contractA.stream('x').toList().timeout(Duration(seconds: 5));
      expect(items.map((r) => r.text).toList(), ['B:1:x', 'B:2:x', 'B:3:x']);
    });

    test('client stream', () async {
      final resp = await contractA
          .collect(['a', 'b', 'c']).timeout(Duration(seconds: 5));
      expect(resp.text, 'B:a,b,c');
    });

    test('bidirectional stream', () async {
      final ctrl = StreamController<String>();
      final future = contractA.mirror(ctrl.stream).take(3).toList();

      await Future.delayed(Duration(milliseconds: 1));
      ctrl.add('1');
      ctrl.add('2');
      ctrl.add('3');
      await ctrl.close();

      final items = await future.timeout(Duration(seconds: 5));
      expect(items.map((r) => r.text).toList(), ['B:1', 'B:2', 'B:3']);
    });
  });

  // -------------------------------------------------------------------------
  group('contractB calls peerA (handled by contractA)', () {
    test('unary', () async {
      final resp = await contractB.echo('world');
      expect(resp.text, 'A:world');
      expect(contractA.log, contains('Echo:world'));
    });

    test('server stream', () async {
      final items =
          await contractB.stream('y').toList().timeout(Duration(seconds: 5));
      expect(items.map((r) => r.text).toList(), ['A:1:y', 'A:2:y', 'A:3:y']);
    });

    test('client stream', () async {
      final resp = await contractB
          .collect(['x', 'y', 'z']).timeout(Duration(seconds: 5));
      expect(resp.text, 'A:x,y,z');
    });

    test('bidirectional stream', () async {
      final ctrl = StreamController<String>();
      final future = contractB.mirror(ctrl.stream).take(3).toList();

      await Future.delayed(Duration(milliseconds: 1));
      ctrl.add('p');
      ctrl.add('q');
      ctrl.add('r');
      await ctrl.close();

      final items = await future.timeout(Duration(seconds: 5));
      expect(items.map((r) => r.text).toList(), ['A:p', 'A:q', 'A:r']);
    });
  });

  // -------------------------------------------------------------------------
  group('simultaneous calls in both directions', () {
    test('concurrent unary', () async {
      final results = await Future.wait([
        contractA.echo('from-A'),
        contractB.echo('from-B'),
      ]).timeout(Duration(seconds: 5));

      expect(results[0].text, 'B:from-A');
      expect(results[1].text, 'A:from-B');
    });

    test('multiple sequential calls alternating', () async {
      for (var i = 0; i < 5; i++) {
        final rA = await contractA.echo('A$i');
        expect(rA.text, 'B:A$i');

        final rB = await contractB.echo('B$i');
        expect(rB.text, 'A:B$i');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('lifecycle', () {
    test('closed peerA throws on outgoing call', () async {
      await peerA.close();
      expect(peerA.isActive, isFalse);
      expect(() => contractA.echo('x'), throwsA(isA<StateError>()));
    });

    test('double start is a no-op', () {
      peerA.start();
      peerA.start();
    });
  });

  // -------------------------------------------------------------------------
  group('ping', () {
    test('peerA pings peerB', () async {
      final result = await peerA.ping(timeout: Duration(seconds: 5));
      expect(result.roundTrip, isA<Duration>());
    });

    test('peerB pings peerA', () async {
      final result = await peerB.ping(timeout: Duration(seconds: 5));
      expect(result.roundTrip, isA<Duration>());
    });
  });
}
