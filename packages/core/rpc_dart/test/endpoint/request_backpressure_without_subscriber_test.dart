// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The responder half of the demand chain only worked when a subscriber already
// existed. StreamProcessor.bindToMessageStream resumed its subscription to the
// bound message stream unconditionally, on the reasoning that a handler which
// ignores its request stream cannot pause and should stay unthrottled rather
// than deadlock.
//
// But "ignores its request stream" is not the only way to have no subscriber:
// EVERY handler has none during an async prelude, and
// `await auth(); await for (requests)` is ordinary code. Measured on a bare
// RpcChannelTransport pair, 4 KiB messages against the default 4 MiB window,
// with the handler consuming nothing yet:
//
//   handler awaits 500ms, then drains : 156.3 MiB admitted   (both shapes)
//   handler never subscribes          : 156.3 MiB admitted
//   handler subscribes, then pauses   :   4.0 MiB admitted   <- already worked
//
// So the peer could push its entire payload into server memory during any
// handler's startup. Starting the subscription paused makes "not yet
// listening" behave like "listening and paused".
//
// The sender is an async* generator, so what it is PULLED for is what the
// window actually permitted -- pushing into a StreamController would measure
// nothing, since a controller accepts everything regardless.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Small enough to keep the test quick; the connection window is left at its
/// generous default so the PER-STREAM window is the control under test.
const _window = 256 * 1024;
const _messageBytes = 4 * 1024;
const _windowMessages = _window ~/ _messageBytes; // 64

/// Far more than the window, so an unthrottled sender is unmistakable.
const _target = 4000;

/// Per-test state. A handler leaked by an earlier test keeps a reference to
/// its OWN instance, so it can no longer contaminate the current test's count
/// -- with a shared counter the canary reported "received 4290 of 4000".
final class _Run {
  _Run(this.mode);

  final String mode;
  final Completer<void> gate = Completer<void>();
  int consumed = 0;
}

late _Run _run;

Future<void> _consume(_Run run, Stream<RpcString> requests) async {
  switch (run.mode) {
    case 'deaf':
      await run.gate.future;
    case 'slowstart':
      // An ordinary handler doing async work before it starts reading.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await for (final _ in requests) {
        run.consumed++;
      }
    default:
      await for (final _ in requests) {
        run.consumed++;
      }
  }
}

final class _Contract extends RpcResponderContract {
  _Contract(this.run) : super('Svc');

  final _Run run;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {RpcContext? context}) async* {
        await _consume(run, requests);
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        await _consume(run, requests);
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
})
_connect(_Run run) {
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  const policy = RpcSecurityPolicy(flowControlWindowBytes: _window);
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: policy,
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: policy,
  );
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract(run));
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

/// Starts a call of [shape] and returns a getter for how many messages the
/// sender has been pulled for.
int Function() _startUpload(RpcCallerEndpoint caller, String shape) {
  var sent = 0;
  Stream<RpcString> requests() async* {
    final body = 'x' * _messageBytes;
    for (var i = 0; i < _target; i++) {
      yield body.rpc;
      sent++;
      // Paced, so the peer's grants have time to arrive. Without this the
      // sender empties the whole generator before the first grant lands, which
      // is a DIFFERENT gap (unbounded-until-first-grant) and would mask this
      // one. Pacing cannot cause a false pass: it only reduces what is offered.
      if (i % 16 == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  if (shape == 'bidi') {
    caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Chat',
          requests: requests(),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});
  } else {
    final call = caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Upload',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    unawaited(call(requests()).then((_) {}, onError: (Object _) {}));
  }
  return () => sent;
}

void main() {
  tearDown(() {
    if (!_run.gate.isCompleted) _run.gate.complete();
  });

  for (final shape in const ['bidi', 'client']) {
    test(
      '$shape: a handler that never subscribes still bounds its peer',
      () async {
        final run = _run = _Run('deaf');
        final c = _connect(run);
        final sent = _startUpload(c.caller, shape);

        // A bounded assertion may use a fixed delay: contention only reduces
        // what the sender offers, so it cannot cause a false pass.
        await Future<void>.delayed(const Duration(milliseconds: 800));

        expect(
          run.consumed,
          0,
          reason: 'the handler was meant to consume nothing',
        );
        expect(
          sent(),
          lessThan(_windowMessages * 4),
          reason:
              'sender was pulled for ${sent()} of $_target messages '
              '(${sent() * _messageBytes ~/ 1024} KiB) against a '
              '${_window ~/ 1024} KiB window, with the handler consuming none',
        );

        run.gate.complete();
        await c.caller.close();
        await c.responder.close();
        await c.client.close();
        await c.server.close();
      },
    );

    test('$shape: an async prelude does not open the window', () async {
      // The reachability case: ordinary code, not a pathological handler.
      final run = _run = _Run('slowstart');
      final c = _connect(run);
      final sent = _startUpload(c.caller, shape);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      final duringPrelude = sent();
      expect(
        duringPrelude,
        lessThan(_windowMessages * 4),
        reason:
            'sender was pulled for $duringPrelude of $_target messages while '
            'the handler was still in its async prelude',
      );

      // GUARD: once the handler starts reading, everything still gets through.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(
        run.consumed,
        greaterThan(duringPrelude),
        reason: 'the handler never resumed after its prelude',
      );

      await c.caller.close();
      await c.responder.close();
      await c.client.close();
      await c.server.close();
    });

    test('$shape: a draining handler still receives everything', () async {
      // GUARD (passes both sides): the fix must not throttle a live consumer.
      final run = _run = _Run('hungry');
      final c = _connect(run);
      _startUpload(c.caller, shape);

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (run.consumed < _target && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        run.consumed,
        _target,
        reason: 'a consuming handler received only ${run.consumed} of $_target',
      );

      await c.caller.close();
      await c.responder.close();
      await c.client.close();
      await c.server.close();
    });
  }
}
