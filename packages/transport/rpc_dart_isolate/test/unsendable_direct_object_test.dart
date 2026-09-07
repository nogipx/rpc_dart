// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A ZERO-COPY method on this transport passes request/response OBJECTS straight
// to `SendPort.send`, so an object can be unsendable (a Future, Timer or
// ReceivePort anywhere in its graph). The channel used to answer that with
// `catch (_) { close(); }`, which is the wrong blast radius by two steps:
//
//   * `SendPort.send` throws for exactly ONE reason -- an unsendable payload.
//     A closed ReceivePort and a killed isolate both accept a send and drop it,
//     so a throw never means "the peer is gone".
//   * closing took down every other call on the connection and killed the
//     worker, and `catch (_)` dropped the cause, so the caller saw UNAVAILABLE.
//
// Measured on one poisoned unary call, with an unrelated server stream running:
//
//                        before                        after
//   poisoned call        UNAVAILABLE "stream closed"   ArgumentError naming the
//                                                      unsendable field
//   unrelated stream     stopped at 7 of 1000          still running (21)
//   next call            "Transport is closed"         succeeded
//
// These witnesses were written against the CODEC service, because unary used to
// send the raw object regardless of the codecs its method declared. Round 165
// fixed that, so a codec-declared call can no longer carry an unsendable field
// at all -- and the witnesses moved to the zero-copy service, which is now the
// only place a raw object crosses.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

const _service = 'isolate.Unsendable';

class Req implements IRpcSerializable {
  Req(this.text, {this.trap});

  final String text;

  /// Deliberately outside the wire form: the CODEC never sees it, so a codec-
  /// declared method has no reason to reject this object.
  final Object? trap;

  @override
  Map<String, dynamic> toJson() => {'text': text};

  static Req fromJson(Map<String, dynamic> json) => Req(json['text'] as String);
}

class Res implements IRpcSerializable {
  Res(this.text, this.index);

  final String text;
  final int index;

  @override
  Map<String, dynamic> toJson() => {'text': text, 'index': index};

  static Res fromJson(Map<String, dynamic> json) =>
      Res(json['text'] as String, json['index'] as int);
}

const _req = RpcCodec<Req>(Req.fromJson);
const _res = RpcCodec<Res>(Res.fromJson);

/// Plain objects for the genuine zero-copy contract below (no codecs).
class ZcReq {
  const ZcReq(this.text, {this.trap});
  final String text;

  /// Makes the object unsendable. With no codec in the picture this object IS
  /// what crosses, so the whole graph has to be sendable.
  final Object? trap;
}

class ZcRes {
  ZcRes(this.index, {this.trap});
  final int index;
  final Object? trap;
}

const _zcService = 'isolate.UnsendableZc';

@pragma('vm:entry-point')
void unsendableWorkerEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  final contract = _Worker();
  contract.setup();
  endpoint.registerServiceContract(contract);
  final zc = _ZcWorker();
  zc.setup();
  endpoint.registerServiceContract(zc);
  endpoint.start();
}

final class _ZcWorker extends RpcResponderContract {
  _ZcWorker()
    : super(_zcService, dataTransferMode: RpcDataTransferMode.zeroCopy);

  @override
  void setup() {
    addServerStreamMethod<ZcReq, ZcRes>(
      methodName: 'Stream',
      handler: (r, {context}) async* {
        for (var i = 0; i < 5; i++) {
          yield i == 2 ? ZcRes(i, trap: Future<int>.value(1)) : ZcRes(i);
        }
      },
    );

    addUnaryMethod<ZcReq, ZcRes>(
      methodName: 'Unary',
      handler: (r, {context}) async => ZcRes(0),
    );

    // Reports whether the worker received the SAME instance the host sent.
    addUnaryMethod<ZcReq, ZcRes>(
      methodName: 'Identity',
      handler: (r, {context}) async => ZcRes(identityHashCode(r)),
    );

    addServerStreamMethod<ZcReq, ZcRes>(
      methodName: 'Ticks',
      handler: (r, {context}) async* {
        for (var i = 0; i < 2000; i++) {
          yield ZcRes(i);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
    );
  }
}

final class _Worker extends RpcResponderContract {
  _Worker() : super(_service, dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    addUnaryMethod<Req, Res>(
      methodName: 'Unary',
      requestCodec: _req,
      responseCodec: _res,
      handler: (r, {context}) async => Res('reply:${r.text}', 0),
    );

    // Reports whether the worker received the SAME instance the host sent.
    addUnaryMethod<Req, Res>(
      methodName: 'Identity',
      requestCodec: _req,
      responseCodec: _res,
      handler: (r, {context}) async => Res(r.text, identityHashCode(r)),
    );

    addServerStreamMethod<Req, Res>(
      methodName: 'Ticks',
      requestCodec: _req,
      responseCodec: _res,
      handler: (r, {context}) async* {
        for (var i = 0; i < 2000; i++) {
          yield Res('tick', i);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
    );
  }
}

void main() {
  late ({IRpcTransport transport, void Function() kill}) spawned;
  late RpcCallerEndpoint caller;

  Future<Res> unary(
    String method,
    Req request, {
    RpcDataTransferMode mode = RpcDataTransferMode.auto,
  }) => caller.unaryRequest<Req, Res>(
    serviceName: _service,
    methodName: method,
    request: request,
    requestCodec: _req,
    responseCodec: _res,
    transferMode: mode,
  );

  /// No codecs: the object itself crosses, which is the only path left where an
  /// unsendable field can reach `SendPort.send`.
  Future<ZcRes> zcUnary(String method, ZcReq request) =>
      caller.unaryRequest<ZcReq, ZcRes>(
        serviceName: _zcService,
        methodName: method,
        request: request,
      );

  setUp(() async {
    spawned = await RpcIsolateTransport.spawn(
      entrypoint: unsendableWorkerEntrypoint,
      isolateId: 'unsendable',
      debugName: 'UnsendableWorker',
    );
    caller = RpcCallerEndpoint(transport: spawned.transport);
  });

  tearDown(() async {
    await caller.close();
    spawned.kill();
  });

  test(
    'an unsendable request fails ITS call, naming the cause',
    () async {
      // WITNESS. Pre-fix this arrived as RpcStatusException(14) "Stream closed
      // without receiving response" -- the connection dying, with the real
      // reason swallowed by `catch (_)`.
      await expectLater(
        zcUnary('Unary', ZcReq('poison', trap: Future<int>.value(1))),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('isolate boundary'), contains('unsendable')),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the connection survives a poisoned call',
    () async {
      // WITNESS. Pre-fix every later call failed with "Transport is closed".
      await expectLater(
        zcUnary('Unary', ZcReq('poison', trap: Future<int>.value(1))),
        throwsA(isA<ArgumentError>()),
      );

      final after = await unary('Unary', Req('after'));
      expect(after.text, 'reply:after');

      final health = await spawned.transport.health();
      expect(health.isHealthy, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'an unrelated in-flight stream is not collateral damage',
    () async {
      // WITNESS, and the one that shows the real cost: pre-fix this stream
      // stopped dead the moment an unrelated call was poisoned.
      var ticks = 0;
      Object? streamError;
      final sub = caller
          .serverStream<Req, Res>(
            serviceName: _service,
            methodName: 'Ticks',
            request: Req('go'),
            requestCodec: _req,
            responseCodec: _res,
          )
          .listen((_) => ticks++, onError: (Object e) => streamError ??= e);
      addTearDown(sub.cancel);

      // Wait for it to RISE before asserting it keeps rising: polling straight
      // for growth succeeds on a stream that never started.
      while (ticks == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final before = ticks;

      await expectLater(
        zcUnary('Unary', ZcReq('poison', trap: Future<int>.value(1))),
        throwsA(isA<ArgumentError>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(ticks, greaterThan(before));
      expect(streamError, isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary call is not refused',
    () async {
      // Pairs with the witnesses above. Without it a mistyped "poison" fixture
      // would make them pass while proving nothing.
      final response = await unary('Unary', Req('hello'));
      expect(response.text, 'reply:hello');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a direct object is COPIED, not shared',
    () async {
      // Pins the corrected doc claim. `supportsZeroCopy` on this transport means
      // "sendDirectObject works", not "the peer gets the same instance" --
      // SendPort.send deep-copies anything that is not deeply immutable.
      //
      // On the ZERO-COPY service: through a codec the identity differs for the
      // trivial reason that `fromJson` built a new object, which would prove
      // nothing about copying.
      final request = ZcReq('identity');
      final response = await zcUnary('Identity', request);
      expect(response.index, isNot(identityHashCode(request)));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an explicit codec mode carries no raw object at all',
    () async {
      // The same poison that fails an object-path call is simply not on the
      // wire when the caller asks for codecs, because `toJson` never looks at
      // it. `auto` -- the default -- still takes the object path here, which is
      // why the mode has to be spelled out.
      final response = await unary(
        'Unary',
        Req('codec', trap: Future<int>.value(1)),
        mode: RpcDataTransferMode.codec,
      );
      expect(response.text, 'reply:codec');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a stream item that cannot be sent fails the call, not just that item',
    () async {
      // Round 158 stopped one bad message from killing the connection. That left
      // the response side reporting grpc-status 0 for a stream the peer never
      // fully received -- silent data loss, fixed in StreamProcessor.
      final items = <int>[];
      Object? error;
      final settled = Completer<void>();
      final sub = caller
          .serverStream<ZcReq, ZcRes>(
            serviceName: _zcService,
            methodName: 'Stream',
            request: const ZcReq('go'),
          )
          .listen(
            (r) => items.add(r.index),
            onError: (Object e) {
              error ??= e;
              if (!settled.isCompleted) settled.complete();
            },
            onDone: () {
              if (!settled.isCompleted) settled.complete();
            },
          );
      addTearDown(sub.cancel);
      await settled.future.timeout(const Duration(seconds: 20));

      expect(
        error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.internal,
        ),
        reason: 'the peer must not be told a truncated stream succeeded',
      );
      expect(items, isNot(contains(2)));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a dead worker still ends the connection',
    () async {
      // The removed `close()` was never what detected a dead peer -- onExit is.
      // This pins that the real mechanism still fires.
      expect((await spawned.transport.health()).isHealthy, isTrue);
      spawned.kill();

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var healthy = true;
      while (DateTime.now().isBefore(deadline) && healthy) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        healthy = (await spawned.transport.health()).isHealthy;
      }
      expect(
        healthy,
        isFalse,
        reason: 'a killed worker must close the channel',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
