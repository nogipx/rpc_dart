// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The request-direction twin of slow_reader_backpressure_test.
//
// A client uploading into a handler that is not consuming must be throttled.
// On HTTP/2 it was not, and the transport was the odd one out: paced 4 KiB
// messages, handler consuming nothing, bytes measured ON THE WIRE --
//
//   websocket : 4.4 MiB, flat from t=2s
//   http2     : 13.8 MiB at 12s and climbing ~1 MiB/s, never plateauing
//
// Two distinct feeds needed connecting, because the responder pipeline builds
// the handler's request stream differently per shape:
//
//   client-stream : `_pipelineFedRequestStream`, which reports demand through
//                   IRpcFlowControlled -- and RpcHttp2ResponderTransport did
//                   not implement it, so RpcHttp2Server's `_flowControlled`
//                   was null and deferFlowCredit/returnFlowCredit were no-ops.
//   bidirectional : `_stateBoundStream`, which subscribes to
//                   getMessagesForStream and never calls deferFlowCredit, so
//                   that controller needed onPause/onResume.
//
// After: client-stream 4.4 MiB flat, bidirectional 0.1 MiB flat.
//
// package:http2 makes this work: `_tryDispatch` only calls
// `windowHandler.dataProcessed` -- which is what emits WINDOW_UPDATE -- when
// `_incomingMessagesC.hasListener && !_incomingMessagesC.isPaused`. Pausing our
// subscription therefore closes the receive window, which is the lever.
//
// MEASURE THE WIRE, NOT THE SENDER. The caller's `sendData` is fire-and-forget,
// so once the server stops reading the client keeps draining its own request
// generator into package:http2's outgoing queue at full speed. Counting what
// the sender produced shows 156 MiB either way and hides the fix completely;
// only the bytes that reach the server show it.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Per-test state, so a handler left running by an earlier test cannot count
/// into the next one.
final class _Run {
  final Completer<void> gate = Completer<void>();
  int consumed = 0;
}

late _Run _run;

Future<void> _consume(_Run run, Stream<RpcString> requests, String mode) async {
  if (mode == 'deaf') {
    await run.gate.future;
    return;
  }
  await for (final _ in requests) {
    run.consumed++;
  }
}

final class _Contract extends RpcResponderContract {
  _Contract(this.run, this.mode) : super('Svc');

  final _Run run;
  final String mode;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        await _consume(run, requests, mode);
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {RpcContext? context}) async* {
        await _consume(run, requests, mode);
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Counts client->server bytes by relaying raw TCP, so the WebSocket/HTTP2
/// framing passes through untouched.
final class _Relay {
  int bytes = 0;
  late final ServerSocket _listener;

  Future<int> start(int targetPort) async {
    _listener = await ServerSocket.bind('127.0.0.1', 0);
    _listener.listen((client) async {
      final upstream = await Socket.connect('127.0.0.1', targetPort);
      client.listen(
        (chunk) {
          bytes += chunk.length;
          upstream.add(chunk);
        },
        onDone: () => upstream.close().catchError((Object _) => null),
        onError: (Object _) {},
        cancelOnError: false,
      );
      upstream.listen(
        client.add,
        onDone: () => client.close().catchError((Object _) => null),
        onError: (Object _) {},
        cancelOnError: false,
      );
    });
    return _listener.port;
  }

  Future<void> stop() => _listener.close();
}

const _messageBytes = 4 * 1024;
const _target = 40000; // 156 MiB if nothing stops it

void main() {
  tearDown(() {
    if (!_run.gate.isCompleted) _run.gate.complete();
  });

  test(
    'the client does not buffer its request when the server stalls',
    () async {
      // The other half of the same stall: even once the SERVER is protected, the
      // caller's `sendData` is fire-and-forget, so the client drained its whole
      // request into package:http2's outgoing queue -- 156.3 MiB pulled while
      // 4.4 MiB was on the wire, i.e. ~152 MiB held in client memory. Routing
      // sends through RpcHttp2OutgoingPump makes the client park instead.
      //
      // Asserting on PULLED-vs-WIRE, since the gap between them IS the buffer.
      final run = _run = _Run();
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Contract(run, 'deaf')),
      );
      await server.start();
      final relay = _Relay();
      final port = await relay.start(server.port);
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: port,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      final body = 'x' * _messageBytes;
      var pulled = 0;
      Stream<RpcString> requests() async* {
        for (var i = 0; i < _target; i++) {
          yield body.rpc;
          pulled++;
          if (i % 50 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
      }

      final call = caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Upload',
        requestCodec: _codec,
        responseCodec: _codec,
      );
      unawaited(call(requests()).then((_) {}, onError: (Object _) {}));

      await Future<void>.delayed(const Duration(seconds: 8));

      final held = pulled * _messageBytes - relay.bytes;
      expect(
        held,
        lessThan(8 * 1024 * 1024),
        reason:
            'client pulled ${(pulled * _messageBytes / 1024 / 1024).toStringAsFixed(1)} MiB '
            'but only ${(relay.bytes / 1024 / 1024).toStringAsFixed(1)} MiB '
            'reached the wire: ${(held / 1024 / 1024).toStringAsFixed(1)} MiB is '
            'sitting in the client',
      );

      run.gate.complete();
      await transport.close().catchError((Object _) {});
      await server.stop();
      await relay.stop();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  for (final shape in const ['client', 'bidi']) {
    test(
      '$shape: an upload into a non-consuming handler is throttled',
      () async {
        final run = _run = _Run();
        final server = RpcHttp2Server(
          host: '127.0.0.1',
          port: 0,
          onEndpointCreated: (e) =>
              e.registerServiceContract(_Contract(run, 'deaf')),
        );
        await server.start();
        final relay = _Relay();
        final port = await relay.start(server.port);
        final transport = await RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: port,
        );
        final caller = RpcCallerEndpoint(transport: transport);

        final body = 'x' * _messageBytes;
        Stream<RpcString> requests() async* {
          for (var i = 0; i < _target; i++) {
            yield body.rpc;
            // Paced, so window updates have time to matter. Pacing can only
            // reduce what is offered, never cause a false pass.
            if (i % 50 == 0) {
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

        // Long enough that steady growth cannot be mistaken for a ceiling: the
        // unfixed transport reached 13.8 MiB here and was still climbing.
        await Future<void>.delayed(const Duration(seconds: 8));

        expect(run.consumed, 0, reason: 'the handler was to consume nothing');
        // Fixed: 4.4 MiB (client-stream) and 0.1 MiB (bidi). Unfixed at this
        // point: 10.2 and 10.5 MiB, still climbing. 8 MiB sits clear of both.
        expect(
          relay.bytes,
          lessThan(8 * 1024 * 1024),
          reason:
              '${(relay.bytes / 1024 / 1024).toStringAsFixed(1)} MiB reached the '
              'server for a handler consuming nothing',
        );

        run.gate.complete();
        await transport.close().catchError((Object _) {});
        await server.stop();
        await relay.stop();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '$shape: a consuming handler still receives its upload',
      () async {
        // GUARD (passes both sides): throttling must not cost throughput.
        final run = _run = _Run();
        final server = RpcHttp2Server(
          host: '127.0.0.1',
          port: 0,
          onEndpointCreated: (e) =>
              e.registerServiceContract(_Contract(run, 'hungry')),
        );
        await server.start();
        final transport = await RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: server.port,
        );
        final caller = RpcCallerEndpoint(transport: transport);

        final body = 'x' * _messageBytes;
        Stream<RpcString> requests() async* {
          for (var i = 0; i < 500; i++) {
            yield body.rpc;
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

        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (run.consumed < 500 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          run.consumed,
          500,
          reason: 'a consuming handler received only ${run.consumed} of 500',
        );

        await transport.close().catchError((Object _) {});
        await server.stop();
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }
}
