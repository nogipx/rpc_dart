// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client that stops reading must slow the server down. On HTTP/2 it did not,
// and the transport was the odd one out among its siblings: same handler, same
// client, client pauses after 5 items, measured over 4 seconds --
//
//   websocket : +1023 items (4.0 MiB), flat        <- the rpc-level window
//   http2     : +33906 items (132.4 MiB), climbing
//
// Not for lack of flow control: HTTP/2 has native windows, and because it does,
// rpc_dart sets the rpc-level window to null there. Two hops were bypassing the
// native one, and BOTH were load-bearing (ablated separately):
//
//   1. Caller: getMessagesForStream returned a controller with no onPause, so
//      package:http2 kept draining the socket and issuing WINDOW_UPDATE no
//      matter what the application did -- the server's window never closed.
//   2. Responder: TransportStream.sendData is `outgoingMessages.add(...)`, and
//      a StreamSink add never blocks. package:http2 pauses its own outgoing
//      subscription once the queue would buffer, but an add into the controller
//      behind that subscription just enqueues.
//
//   server pump only    : +38204 items (149.2 MiB)  UNBOUNDED
//   caller hop only     : +233743 items (913.1 MiB) UNBOUNDED -- WORSE, the
//                         bytes just moved into the server's own h2 queue
//   both                : +16 items (0.1 MiB)       BOUNDED
//
// Asserting a BOUND, so a fixed delay is sound: contention only reduces what
// the handler produces and cannot cause a false pass.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Per-test state, so a handler left running by an earlier test cannot count
/// into the next one.
final class _Run {
  int produced = 0;
  final Completer<void> stop = Completer<void>();
}

late _Run _run;

final class _Contract extends RpcResponderContract {
  _Contract(this.run) : super('Svc');

  final _Run run;

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Firehose',
      handler: (request, {RpcContext? context}) async* {
        final body = 'y' * 4096;
        while (!run.stop.isCompleted) {
          yield body.rpc;
          run.produced++;
          // Give the runtime a chance to apply the pause; without this the
          // generator never yields and the test measures its own tight loop.
          await Future<void>.delayed(Duration.zero);
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  tearDown(() {
    if (!_run.stop.isCompleted) _run.stop.complete();
  });

  test(
    'a client that stops reading stops the server producing',
    () async {
      final run = _run = _Run();
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract(run)),
      );
      await server.start();
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      var received = 0;
      final paused = Completer<void>();
      late StreamSubscription<RpcString> sub;
      sub = caller
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
              if (received == 5 && !paused.isCompleted) {
                sub.pause();
                paused.complete();
              }
            },
            onError: (Object _) {},
            cancelOnError: false,
          );

      await paused.future.timeout(const Duration(seconds: 30));
      final atPause = run.produced;
      await Future<void>.delayed(const Duration(seconds: 3));
      final overrun = run.produced - atPause;

      expect(
        overrun,
        lessThan(2000),
        reason:
            'handler produced $overrun more items '
            '(${(overrun * 4096 / 1024 / 1024).toStringAsFixed(1)} MiB) while '
            'the client was paused; the peer window is not reaching it',
      );

      // GUARD: throttling must not break delivery.
      sub.resume();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (received < 50 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        received,
        greaterThan(50),
        reason: 'after resume the client received only $received items',
      );

      run.stop.complete();
      await sub.cancel();
      await transport.close().catchError((Object _) {});
      await server.stop();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'an ordinary server stream is unaffected',
    () async {
      // GUARD (passes both sides): a consumer that keeps reading gets everything,
      // so the backpressure does not cost throughput or truncate.
      final run = _run = _Run();
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Contract(run)),
      );
      await server.start();
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      final got = <RpcString>[];
      final done = Completer<void>();
      final sub = caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Firehose',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (m) {
              got.add(m);
              if (got.length == 200 && !done.isCompleted) done.complete();
            },
            onError: (Object _) {},
            cancelOnError: false,
          );

      await done.future.timeout(const Duration(seconds: 30));
      expect(got.length, greaterThanOrEqualTo(200));

      run.stop.complete();
      await sub.cancel();
      await transport.close().catchError((Object _) {});
      await server.stop();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
