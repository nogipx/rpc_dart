// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The shelf handler returns `pending.completer.future`, and `releaseStreamId`
// removed the entry without completing it. Every stream torn down before it
// answered therefore left an HTTP request open until the client gave up, with
// the request object and the handler closure reachable behind it.
//
// The ordinary way in is the pipeline's deadline reclaim, which cancels the
// handler's token and, two seconds later, cleans the stream up WITHOUT a
// trailer — deliberately, so a handler that ignores its token is exactly the
// case. Measured with one unary call, deadline 500 ms:
//
//   handler ignores its token     requests arrived 1, answered 0
//   handler cooperates (control)  requests arrived 1, answered 1
//
// `health()` reads `_pending`, so it reported `pendingRequests: 0` in both —
// the drain saw an idle server with a response still unwritten.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc({required this.cooperative}) : super('Svc');

  final bool cooperative;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        if (cooperative) {
          await context?.cancellationToken?.cancelled;
          throw RpcStatusException(RpcStatus.cancelled, 'gave up');
        }
        await Future<void>.delayed(const Duration(seconds: 10));
        return 'late:${req.value}'.rpc;
      },
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  int Function() arrived,
  int Function() answered,
});

Future<_Rig> _serve({required bool cooperative}) async {
  var arrived = 0;
  var answered = 0;

  final responder = RpcHttpResponderTransport();
  final endpoint = RpcResponderEndpoint(transport: responder)
    ..registerServiceContract(_Svc(cooperative: cooperative)..setup())
    ..start();

  // Counted around the responder's own handler, so "answered" means the future
  // the shelf server is awaiting actually completed.
  final server = await shelf_io.serve(
    (shelf.Request req) async {
      arrived++;
      final response = await responder.handler(req);
      answered++;
      return response;
    },
    '127.0.0.1',
    0,
  );

  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.port}',
    ),
  );
  addTearDown(() async {
    await caller.close();
    await endpoint.close();
    await server.close(force: true);
  });

  return (caller: caller, arrived: () => arrived, answered: () => answered);
}

Future<void> _callWithDeadline(RpcCallerEndpoint caller) async {
  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'slow',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.empty().withTimeout(
            const Duration(milliseconds: 500),
          ),
        )
        .timeout(const Duration(seconds: 4));
  } catch (_) {
    // The caller's own deadline fires either way; this test is about the SERVER.
  }
}

/// Polls rather than sleeps: the reclaim runs 2 s after the deadline and a
/// fixed wait is a flake on a loaded machine.
Future<void> _awaitAnswered(int Function() answered) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (answered() < 1 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test(
    'WITNESS: a stream released before it answered still closes its request',
    () async {
      final rig = await _serve(cooperative: false);
      await _callWithDeadline(rig.caller);
      await _awaitAnswered(rig.answered);

      expect(rig.arrived(), 1);
      expect(
        rig.answered(),
        1,
        reason:
            'the shelf request is awaiting a completer nobody completed, so it '
            'stays open until the client gives up',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: a handler that cooperates answered all along',
    () async {
      final rig = await _serve(cooperative: true);
      await _callWithDeadline(rig.caller);
      await _awaitAnswered(rig.answered);

      expect(rig.arrived(), 1);
      expect(rig.answered(), 1);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: an ORDINARY call must still be answered exactly once. `_flushResponse`
  // removes the pending entry before `releaseStreamId` sees it, and a second
  // completion would throw `Bad state: Future already completed` into the
  // pipeline rather than failing here.
  test(
    'GUARD: a normal call is answered once, with its own status',
    () async {
      var arrived = 0;
      var answered = 0;
      final responder = RpcHttpResponderTransport();
      final endpoint = RpcResponderEndpoint(transport: responder)
        ..registerServiceContract(_Echo()..setup())
        ..start();
      final server = await shelf_io.serve(
        (shelf.Request req) async {
          arrived++;
          final response = await responder.handler(req);
          answered++;
          return response;
        },
        '127.0.0.1',
        0,
      );
      final caller = RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      );
      addTearDown(() async {
        await caller.close();
        await endpoint.close();
        await server.close(force: true);
      });

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));

      expect(reply.value, 'echo:hi');
      expect(arrived, 1);
      expect(answered, 1);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}
