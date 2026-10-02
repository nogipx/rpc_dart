// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A handler answering NOT_FOUND is a working server, but the failure was logged at
// `error` on both sides — twice on the caller — so an ordinary answer read as an
// incident in three log records.
//
// The level now follows the STATUS: `RpcStatus.isFault` marks the codes that mean
// something broke, and only those reach `error`.
//
// Counted by overriding `LogController.add`, NOT by subclassing `LogScope`:
// `child()` returns a plain `LogScope`, so a subclass override is lost as soon as
// the code derives a scope — which is what round 515 discovered, and both endpoints
// here derive.
//
// The measurements are in `.claude/loop/rounds/516`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Counting extends LogController {
  _Counting() : super(minLevel: RpcLogLevel.debug);

  final loud = <String>[];

  @override
  void add(LogRecord record) {
    if (record is LogEvent &&
        (record.level == RpcLogLevel.error ||
            record.level == RpcLogLevel.warning)) {
      loud.add('${record.level.name}  ${record.message}');
    }
    super.add(record);
  }
}

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'missing',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.notFound, 'no such record'),
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'denied',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.permissionDenied, 'no'),
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ok',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok'.rpc,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'broken',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.internal, 'the database is gone'),
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'crash',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => throw StateError('boom'),
    );
    for (final (name, code) in [
      ('Missing', RpcStatus.notFound),
      ('Broken', RpcStatus.internal),
    ]) {
      addServerStreamMethod<RpcString, RpcString>(
        methodName: 'server$name',
        requestCodec: _codec,
        responseCodec: _codec,
        handler: (req, {context}) async* {
          throw RpcStatusException(code, 'answer');
        },
      );
      addClientStreamMethod<RpcString, RpcString>(
        methodName: 'client$name',
        requestCodec: _codec,
        responseCodec: _codec,
        handler: (reqs, {context}) async {
          await reqs.drain<void>();
          throw RpcStatusException(code, 'answer');
        },
      );
      addBidirectionalMethod<RpcString, RpcString>(
        methodName: 'bidi$name',
        requestCodec: _codec,
        responseCodec: _codec,
        handler: (reqs, {context}) async* {
          await reqs.drain<void>();
          throw RpcStatusException(code, 'answer');
        },
      );
    }
  }
}

/// The same count for a STREAMING call of [shape] (`server`, `client`, `bidi`).
Future<_Loud> _stream(String shape, String outcome) async {
  final callerLog = _Counting();
  final responderLog = _Counting();
  final (client, server) = RpcChannelTransport.pair();
  final responder =
      RpcResponderEndpoint(transport: server, logger: responderLog)
        ..registerServiceContract(_Svc())
        ..start();
  final caller = RpcCallerEndpoint(transport: client, logger: callerLog);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final method = '$shape$outcome';
  final ctx = RpcContext.empty().withTimeout(const Duration(seconds: 5));
  try {
    switch (shape) {
      case 'server':
        await caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: method,
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: ctx,
            )
            .drain<void>();
      case 'client':
        await caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        )(Stream.value('x'.rpc));
      default:
        await caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: method,
              requests: Stream.value('x'.rpc),
              requestCodec: _codec,
              responseCodec: _codec,
              context: ctx,
            )
            .drain<void>();
    }
  } on RpcStatusException {
    // expected
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return (caller: callerLog.loud, responder: responderLog.loud);
}

typedef _Loud = ({List<String> caller, List<String> responder});

Future<_Loud> _call(String method) async {
  final callerLog = _Counting();
  final responderLog = _Counting();
  final (client, server) = RpcChannelTransport.pair();
  final responder =
      RpcResponderEndpoint(transport: server, logger: responderLog)
        ..registerServiceContract(_Svc())
        ..start();
  final caller = RpcCallerEndpoint(transport: client, logger: callerLog);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
    );
  } on RpcStatusException {
    // expected for the failing arms
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return (caller: callerLog.loud, responder: responderLog.loud);
}

void main() {
  group('WITNESS: an application status is not an incident', () {
    test(
      'NOT_FOUND produces no error or warning on either side',
      () async {
        final loud = await _call('missing');
        expect(
          loud.caller,
          isEmpty,
          reason:
              'the caller logged the status AND the failure, so one ordinary '
              'answer produced two error records',
        );
        expect(
          loud.responder,
          isEmpty,
          reason: 'a handler answering NOT_FOUND is a working server',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('PERMISSION_DENIED likewise', () async {
      final loud = await _call('denied');
      expect(loud.caller, isEmpty);
      expect(loud.responder, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('GUARD: a genuine fault is still reported', () {
    test(
      'INTERNAL reaches error on both sides',
      () async {
        // Without this, silencing everything would pass the witness.
        final loud = await _call('broken');
        // ONE caller record: the call's own, which carries the error, the
        // method path and the stack. The trailer site logs at debug.
        expect(loud.caller, hasLength(1), reason: '${loud.caller}');
        expect(loud.responder, isNotEmpty);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a throw with NO status reaches error on both sides',
      () async {
        // A crashed handler carries no status to classify, so it must be treated
        // as a fault rather than fall through the new branch as "not a fault".
        final loud = await _call('crash');
        expect(loud.caller, isNotEmpty);
        expect(loud.responder, isNotEmpty);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('a successful call is silent', () async {
      final loud = await _call('ok');
      expect(loud.caller, isEmpty);
      expect(loud.responder, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('the streaming shapes', () {
    for (final shape in ['server', 'client', 'bidi']) {
      test(
        'WITNESS $shape: NOT_FOUND is not an incident',
        () async {
          final loud = await _stream(shape, 'Missing');
          // Both sides in one assertion, so a failure names every record.
          expect([
            for (final r in loud.caller) 'caller     $r',
            for (final r in loud.responder) 'responder  $r',
          ], isEmpty);
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test(
        'GUARD $shape: INTERNAL still reaches error',
        () async {
          final loud = await _stream(shape, 'Broken');
          expect(loud.responder, isNotEmpty);
          // One caller record per failed call, as for unary.
          expect(loud.caller, hasLength(1), reason: '${loud.caller}');
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  });

  test('GUARD: isFault is narrower than the breaker\'s health set', () {
    // Both classify statuses and they answer different questions, so they are
    // deliberately not the same set. Pinning it here stops a later edit
    // "unifying" them and making a slow server page someone.
    expect(RpcStatus.isFault(RpcStatus.internal), isTrue);
    expect(RpcStatus.isFault(RpcStatus.unknown), isTrue);
    expect(RpcStatus.isFault(RpcStatus.unavailable), isTrue);
    expect(RpcStatus.isFault(RpcStatus.dataLoss), isTrue);

    expect(RpcStatus.isFault(RpcStatus.notFound), isFalse);
    expect(RpcStatus.isFault(RpcStatus.permissionDenied), isFalse);
    expect(RpcStatus.isFault(RpcStatus.invalidArgument), isFalse);
    expect(
      RpcStatus.isFault(RpcStatus.deadlineExceeded),
      isFalse,
      reason: 'a slow server is not a broken one',
    );
    expect(
      RpcStatus.isFault(RpcStatus.resourceExhausted),
      isFalse,
      reason: 'a throttled server is not a broken one',
    );
  });
}
