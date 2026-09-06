// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client that cancels a server stream must stop the server's handler.
//
// It did not. The caller does send RST_STREAM (`resetStream` -> `terminate()`,
// verified by tracing), but package:http2 reports a reset to the server only
// through `TransportStream.onTerminated`, and nothing registered it. The
// responder's `onError` branch catches a reset only while `incomingMessages` is
// still live -- and for a server-stream or unary call the client half-closes as
// soon as its request is out, so `onDone` has already run and the subscription
// is gone by the time the cancel arrives.
//
// Measured, client cancelling and LEAVING THE CONNECTION UP:
//
//   before : handler still producing at +6s, 404715 messages, openStreams=1,
//            and nothing was ever going to stop it
//   after  : 0 further messages, openStreams=0
//   websocket sibling, same probe: 1 further message
//
// Registering `onTerminated` and synthesising the `x-client-cancelled` frame
// reuses the cancellation path the responder pipeline already implements --
// the same one the websocket transport reaches through ordinary metadata.
//
// This also closed a separate lead: a client that simply DISCONNECTS used to
// leave the handler producing for ~3s (130349 messages, ~509 MiB) before
// teardown caught up. With the reset delivered promptly that is 0 too.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Per-test state, so a handler left running by an earlier test cannot count
/// into the next one.
final class _Run {
  int produced = 0;
  bool handlerExited = false;
  RpcResponderEndpoint? endpoint;
}

final class _Contract extends RpcResponderContract {
  _Contract(this.run) : super('Svc');

  final _Run run;

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Firehose',
      handler: (request, {RpcContext? context}) async* {
        try {
          final body = 'y' * 4096;
          while (true) {
            yield body.rpc;
            run.produced++;
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          run.handlerExited = true;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Short',
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < 5; i++) {
          yield 'item-$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<
  ({
    RpcHttp2Server server,
    RpcCallerEndpoint caller,
    RpcHttp2CallerTransport transport,
  })
>
_connect(_Run run) async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) {
      run.endpoint = e;
      e.registerServiceContract(_Contract(run));
    },
  );
  await server.start();
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
  );
  return (
    server: server,
    caller: RpcCallerEndpoint(transport: transport),
    transport: transport,
  );
}

void main() {
  test(
    'cancelling a server stream stops the handler',
    () async {
      final run = _Run();
      final c = await _connect(run);

      var received = 0;
      final ready = Completer<void>();
      late StreamSubscription<RpcString> sub;
      sub = c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Firehose',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (_) {
              received++;
              if (received == 5 && !ready.isCompleted) ready.complete();
            },
            onError: (Object _) {},
            cancelOnError: false,
          );

      await ready.future.timeout(const Duration(seconds: 30));
      await sub.cancel();
      final atCancel = run.produced;

      // The connection stays UP on purpose: transport teardown would stop the
      // handler for unrelated reasons and hide the defect.
      await Future<void>.delayed(const Duration(seconds: 3));

      expect(
        run.produced - atCancel,
        lessThan(500),
        reason:
            'handler produced ${run.produced - atCancel} more messages after the '
            'client cancelled; the reset never reached it',
      );
      expect(
        run.endpoint?.collectEndpointMetrics()['openStreams'],
        0,
        reason: 'the cancelled stream was never released',
      );

      await c.transport.close().catchError((Object _) {});
      await c.server.stop();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'an uncancelled server stream still completes normally',
    () async {
      // GUARD (passes both sides): onTerminated must not fire for a stream that
      // simply ended, or every clean call would be reported as cancelled.
      final run = _Run();
      final c = await _connect(run);

      final got = await c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Short',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(const Duration(seconds: 30));

      expect(got.map((e) => e.value).toList(), [
        'item-0',
        'item-1',
        'item-2',
        'item-3',
        'item-4',
      ]);

      await c.transport.close().catchError((Object _) {});
      await c.server.stop();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'repeated cancels do not accumulate server state',
    () async {
      // Leak accounting: the defect held one stream per abandoned call forever.
      final run = _Run();
      final c = await _connect(run);

      for (var i = 0; i < 15; i++) {
        final ready = Completer<void>();
        var seen = 0;
        late StreamSubscription<RpcString> sub;
        sub = c.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Firehose',
              request: 'go'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen(
              (_) {
                seen++;
                if (seen == 2 && !ready.isCompleted) ready.complete();
              },
              onError: (Object _) {},
              cancelOnError: false,
            );
        await ready.future.timeout(const Duration(seconds: 20));
        await sub.cancel();
      }

      // Poll for the drop rather than sleeping a fixed time: teardown is async.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      var open = -1;
      while (DateTime.now().isBefore(deadline)) {
        open =
            (run.endpoint?.collectEndpointMetrics()['openStreams'] ?? -1)
                as int;
        if (open == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(open, 0, reason: '15 cancelled calls left $open streams open');

      await c.transport.close().catchError((Object _) {});
      await c.server.stop();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
