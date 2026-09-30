// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `maxActiveStreams` released a client's slot at HALF-CLOSE. A unary call
// half-closes as soon as its request is out and then waits for the response, so
// four calls parked on four responses left the whole ceiling free and a second
// batch of four walked through: the field counted senders, not calls.
//
// The slot is now held until the call ENDS — the terminal inbound frame, or
// `releaseStreamId` for a call that never gets one, or `close` for all of them.
//
// The failure mode of that fix runs the other way and is worse: a slot never
// returned refuses every subsequent call for the life of the connection. So the
// second group here is the load-bearing one, and it is larger than the first.
//
// BREAKING: a client that got eight concurrent calls at `maxActiveStreams: 4` now
// gets four.
//
// The measurements are in `.claude/loop/rounds/546`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// One direction of a byte pipe, so each SIDE carries its own policy.
///
/// `RpcChannelTransport.pair(policy:)` gives both sides the same one, and then a
/// refusal is ambiguous: this is about the CLIENT's accounting, and a server
/// refusing at its own ceiling looks identical from the caller.
final class _Side implements IRpcChannel {
  final _ctl = StreamController<Uint8List>();
  late _Side peer;
  bool dropEverything = false;

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (dropEverything) return;
    if (!peer._ctl.isClosed) peer._ctl.add(data);
  }

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }
}

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._release) : super('Svc');

  final Future<void> _release;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => req,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'boom',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.notFound, 'no such thing'),
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'wait',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await _release;
        return 'done'.rpc;
      },
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, _Side serverSide});

/// A caller whose ceiling is [ceiling] and a responder with none.
_Rig _rig(int ceiling, Future<void> release) {
  final clientSide = _Side();
  final serverSide = _Side();
  clientSide.peer = serverSide;
  serverSide.peer = clientSide;

  final policy = RpcSecurityPolicy(maxActiveStreams: ceiling);
  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(
        channel: clientSide,
        policy: policy,
        closeOnOversizedFrame: false,
      ),
      isClient: true,
      policy: policy,
    ),
  );
  final responder =
      RpcResponderEndpoint(
          transport: RpcChannelTransport(
            channel: RpcFrameMultiplexedChannel(channel: serverSide),
            isClient: false,
          ),
        )
        ..registerServiceContract(_Svc(release))
        ..start();

  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller: caller, serverSide: serverSide);
}

/// Runs one call and reports `ok`, `refused`, or the status it got.
Future<String> _call(
  RpcCallerEndpoint caller,
  String method, {
  RpcContext? context,
  RpcCancellationToken? cancelAfter,
}) async {
  final call = caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: method,
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
    context: context ?? RpcContext.empty(),
  );
  if (cancelAfter != null) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    cancelAfter.cancel('test');
  }
  try {
    await call.timeout(const Duration(seconds: 10));
    return 'ok';
  } on RpcStatusException catch (e) {
    return e.statusCode == RpcStatus.resourceExhausted
        ? 'refused'
        : 'status ${e.statusCode}';
  }
}

void main() {
  test(
    'WITNESS a call parked on its response still holds its slot',
    () async {
      final release = Completer<void>();
      final rig = _rig(4, release.future);

      // Four calls that have half-closed and are waiting. The ceiling is full.
      final parked = [
        for (var i = 0; i < 4; i++)
          _call(
            rig.caller,
            'wait',
            context: RpcContext.empty().withTimeout(
              const Duration(seconds: 30),
            ),
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // NOT awaited to completion: a refusal is immediate and an admission parks
      // for as long as the handler does, so waiting for all four would fail as a
      // TIMEOUT and say nothing about which happened.
      final second = [
        for (var i = 0; i < 4; i++)
          _call(
            rig.caller,
            'wait',
            context: RpcContext.empty().withTimeout(
              const Duration(seconds: 30),
            ),
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));

      var refused = 0;
      for (final c in second) {
        final outcome = await c.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () => 'still parked',
        );
        if (outcome == 'refused') refused++;
      }

      expect(
        refused,
        4,
        reason:
            'the slot was released at half-close, so four outstanding calls left '
            'the whole ceiling free',
      );

      release.complete();
      await Future.wait([...parked, ...second]);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('every ending returns the slot', () {
    // The half that runs the wrong way. Each of these runs ceiling + 2 calls
    // sequentially through ONE ending shape: a refusal means an earlier call's
    // slot never came back, which would refuse everything for the life of the
    // connection.
    for (final (name, method, makeContext)
        in <(String, String, RpcContext Function())>[
          ('completion', 'echo', RpcContext.empty),
          ('an error status', 'boom', RpcContext.empty),
          (
            'a deadline',
            'wait',
            () => RpcContext.empty().withTimeout(
              const Duration(milliseconds: 150),
            ),
          ),
        ]) {
      test(name, () async {
        final rig = _rig(2, Completer<void>().future);
        final outcomes = <String>[];
        for (var i = 0; i < 4; i++) {
          outcomes.add(await _call(rig.caller, method, context: makeContext()));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        expect(
          outcomes.where((o) => o == 'refused'),
          isEmpty,
          reason: 'got $outcomes — a slot from an earlier call never came back',
        );
      }, timeout: const Timeout(Duration(seconds: 60)));
    }

    test('a cancelled call', () async {
      final rig = _rig(2, Completer<void>().future);
      final outcomes = <String>[];
      for (var i = 0; i < 4; i++) {
        final token = RpcCancellationToken();
        outcomes.add(
          await _call(
            rig.caller,
            'wait',
            context: RpcContext.empty().withCancellation(token),
            cancelAfter: token,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      expect(
        outcomes.where((o) => o == 'refused'),
        isEmpty,
        reason: 'got $outcomes — a cancelled call kept its slot',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a peer that stops answering', () async {
      final rig = _rig(2, Completer<void>().future);
      rig.serverSide.dropEverything = true;
      final outcomes = <String>[];
      for (var i = 0; i < 4; i++) {
        outcomes.add(
          await _call(
            rig.caller,
            'wait',
            context: RpcContext.empty().withTimeout(
              const Duration(milliseconds: 150),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      expect(
        outcomes.where((o) => o == 'refused'),
        isEmpty,
        reason: 'got $outcomes — a call that never got a frame kept its slot',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  test(
    'CONTROL the ceiling still refuses when the slots ARE held',
    () async {
      // Without this, every "no refusals" assertion above is equally consistent
      // with a ceiling that does nothing at all.
      final rig = _rig(2, Completer<void>().future);
      final calls = [
        for (var i = 0; i < 4; i++)
          _call(
            rig.caller,
            'wait',
            context: RpcContext.empty().withTimeout(
              const Duration(seconds: 20),
            ),
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The two that got in are still parked; the other two were refused straight
      // away, so their futures have already completed.
      var refused = 0;
      for (final c in calls) {
        final outcome = await c.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () => 'still parked',
        );
        if (outcome == 'refused') refused++;
      }
      expect(refused, 2, reason: 'two slots held, two calls refused');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
