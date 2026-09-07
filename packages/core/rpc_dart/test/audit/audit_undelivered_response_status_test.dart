// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response that never reached the peer was reported as a SUCCESSFUL call.
//
// StreamProcessor._transmitResponse wraps codec serialization, compression and
// the transport send in one try, and its catch only logged. The call then went
// on to `finishSending()`, which sent grpc-status 0 -- so the peer saw a stream
// that simply did not contain that item, with no way to tell it was missing.
//
// Measured with a response codec that refuses item 2 of five, over a real
// websocket, and over the isolate transport with an unsendable object:
//
//     before   received [0, 1, 3, 4], onDone, error NONE
//     after    received [0, 1, 3, 4], error RpcStatusException(13)
//
// Nothing here is transport-specific: the same catch covers a codec that throws
// and a compressor that throws.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class Msg implements IRpcSerializable {
  const Msg(this.index);

  final int index;

  @override
  Map<String, dynamic> toJson() => {'index': index};

  static Msg fromJson(Map<String, dynamic> json) => Msg(json['index'] as int);
}

const _plain = RpcCodec<Msg>(Msg.fromJson);

/// Encodes everything except [refuse], which it cannot put on the wire.
class _PickyCodec implements IRpcCodec<Msg> {
  const _PickyCodec(this.refuse);

  final int refuse;

  @override
  Uint8List serialize(Msg message) {
    if (message.index == refuse) {
      throw StateError('codec refuses item ${message.index}');
    }
    return _plain.serialize(message);
  }

  @override
  Msg deserialize(Uint8List bytes) => _plain.deserialize(bytes);
}

const _service = 'Undelivered';

final class _Svc extends RpcResponderContract {
  _Svc() : super(_service);

  @override
  void setup() {
    addServerStreamMethod<Msg, Msg>(
      methodName: 'stream',
      requestCodec: _plain,
      responseCodec: const _PickyCodec(2),
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 5; i++) {
          yield Msg(i);
        }
      },
    );

    addServerStreamMethod<Msg, Msg>(
      methodName: 'healthy',
      requestCodec: _plain,
      responseCodec: _plain,
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 5; i++) {
          yield Msg(i);
        }
      },
    );

    addServerStreamMethod<Msg, Msg>(
      methodName: 'handlerThrows',
      requestCodec: _plain,
      responseCodec: _plain,
      handler: (r, {RpcContext? context}) async* {
        yield const Msg(0);
        throw RpcStatusException(RpcStatus.notFound, 'no such thing');
      },
    );

    addClientStreamMethod<Msg, Msg>(
      methodName: 'collect',
      requestCodec: _plain,
      responseCodec: const _PickyCodec(7),
      handler: (requests, {RpcContext? context}) async {
        await for (final _ in requests) {}
        return const Msg(7);
      },
    );

    addBidirectionalMethod<Msg, Msg>(
      methodName: 'echo',
      requestCodec: _plain,
      responseCodec: const _PickyCodec(1),
      handler: (requests, {RpcContext? context}) async* {
        var i = 0;
        await for (final _ in requests) {
          yield Msg(i++);
        }
      },
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, RpcResponderEndpoint responder});

_Rig _rig() {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(_Svc());
  responder.start();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller: caller, responder: responder);
}

/// Drains [stream], returning what arrived and how it ended.
Future<({List<int> items, Object? error, bool done})> _drain(
  Stream<Msg> stream,
) async {
  final items = <int>[];
  Object? error;
  var done = false;
  final completer = Completer<void>();
  final sub = stream.listen(
    (m) => items.add(m.index),
    onError: (Object e) {
      error ??= e;
      if (!completer.isCompleted) completer.complete();
    },
    onDone: () {
      done = true;
      if (!completer.isCompleted) completer.complete();
    },
  );
  await completer.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  await sub.cancel();
  return (items: items, error: error, done: done);
}

void main() {
  test(
    'a server stream whose response cannot be encoded fails the call',
    () async {
      // WITNESS. Pre-fix: items [0, 1, 3, 4], onDone, error NONE.
      final rig = _rig();
      final result = await _drain(
        rig.caller.serverStream<Msg, Msg>(
          serviceName: _service,
          methodName: 'stream',
          request: const Msg(0),
          requestCodec: _plain,
          responseCodec: _plain,
        ),
      );

      expect(
        result.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.internal,
        ),
        reason: 'an undelivered response must not read as a completed call',
      );
      expect(result.items, isNot(contains(2)), reason: 'item 2 never went out');
    },
  );

  test(
    'a bidirectional response that cannot be encoded fails the call',
    () async {
      // WITNESS. Bidi finishes through finishReceiving() -> finishSending().
      final rig = _rig();
      final requests = StreamController<Msg>();
      final drained = _drain(
        rig.caller.bidirectionalStream<Msg, Msg>(
          serviceName: _service,
          methodName: 'echo',
          requests: requests.stream,
          requestCodec: _plain,
          responseCodec: _plain,
        ),
      );
      for (var i = 0; i < 3; i++) {
        requests.add(Msg(i));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await requests.close();
      final result = await drained;

      expect(
        result.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.internal,
        ),
      );
      expect(result.items, isNot(contains(1)));
    },
  );

  test(
    'GUARD: a client-stream response that cannot be encoded fails the call',
    () async {
      // GUARD, not a witness: the canary showed this shape ALREADY reported
      // INTERNAL, because its single response is the whole call and the caller
      // has nothing to complete with. Kept so the fix does not change it.
      final rig = _rig();
      final requests = StreamController<Msg>();
      final call = rig.caller.clientStream<Msg, Msg>(
        serviceName: _service,
        methodName: 'collect',
        requestCodec: _plain,
        responseCodec: _plain,
      )(requests.stream);
      requests.add(const Msg(0));
      await requests.close();

      await expectLater(
        call.timeout(const Duration(seconds: 10)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.internal,
          ),
        ),
      );
    },
  );

  test('GUARD: a healthy stream still completes cleanly', () async {
    // Pairs with the witnesses: without it a broken finishSending() that always
    // reported INTERNAL would pass every test above.
    final rig = _rig();
    final result = await _drain(
      rig.caller.serverStream<Msg, Msg>(
        serviceName: _service,
        methodName: 'healthy',
        request: const Msg(0),
        requestCodec: _plain,
        responseCodec: _plain,
      ),
    );

    expect(result.error, isNull);
    expect(result.done, isTrue);
    expect(result.items, [0, 1, 2, 3, 4]);
  });

  test("GUARD: the handler's own status is not overwritten", () async {
    // A send failure must not shadow a status the handler chose deliberately.
    final rig = _rig();
    final result = await _drain(
      rig.caller.serverStream<Msg, Msg>(
        serviceName: _service,
        methodName: 'handlerThrows',
        request: const Msg(0),
        requestCodec: _plain,
        responseCodec: _plain,
      ),
    );

    expect(
      result.error,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.notFound,
      ),
    );
  });

  // -- exactly one terminal frame, whatever the ordering ---------------------
  //
  // The failure branch above calls sendError() directly, and sendError() has no
  // `_trailerSent` guard of its own -- so a stream that had already been
  // answered got a SECOND grpc-status. That is a protocol violation on any
  // transport with real stream state, and StreamProcessor is public API, so the
  // ordering is something callers can build.

  group('exactly one terminal frame', () {
    Future<List<String>> drive({
      required bool failASend,
      required bool sendErrorFirst,
    }) async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final trailers = <String>[];
      final tap = clientTransport.incomingMessages.listen((m) {
        final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
        if (status != null) trailers.add(status);
      });

      final processor = StreamProcessor<Msg, Msg>(
        transport: serverTransport,
        streamId: 1,
        serviceName: 'Svc',
        methodName: 'M',
        requestCodec: _plain,
        responseCodec: failASend ? const _PickyCodec(0) : _plain,
      );

      if (failASend) await processor.send(const Msg(0));
      if (sendErrorFirst) {
        await processor.sendError(RpcStatus.notFound, 'explicit');
      }
      await processor.finishSending();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tap.cancel();
      await processor.close();
      await clientTransport.close();
      await serverTransport.close();
      return trailers;
    }

    test(
      'WITNESS: a failed send after an explicit error adds nothing',
      () async {
        // Pre-fix this was ['5', '13'].
        expect(await drive(failASend: true, sendErrorFirst: true), [
          '${RpcStatus.notFound}',
        ]);
      },
    );

    test('GUARD: a clean finish sends OK once', () async {
      expect(await drive(failASend: false, sendErrorFirst: false), [
        '${RpcStatus.ok}',
      ]);
    });

    test('GUARD: an explicit error alone is sent once', () async {
      expect(await drive(failASend: false, sendErrorFirst: true), [
        '${RpcStatus.notFound}',
      ]);
    });

    test('GUARD: a failed send alone still reports INTERNAL', () async {
      expect(await drive(failASend: true, sendErrorFirst: false), [
        '${RpcStatus.internal}',
      ]);
    });
  });
}
