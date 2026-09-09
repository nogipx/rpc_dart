// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Throttling an http2 call by PAUSING the read is what killed the connection.
//
// package:http2 credits the CONNECTION window only for messages it can move
// into a stream's queue, and it will not move them while that stream's consumer
// is paused -- so a stalled call parks up to a whole connection window in
// `_stream2pendingMessages`. When the stream is then reset,
// `stream_handler._closeStreamAbnormally` drops that queue through
// `removeStreamMessageQueue` without ever calling `dataProcessed`, so no
// WINDOW_UPDATE is emitted for bytes the peer was charged for. RFC 9113 6.9.1
// requires that accounting even when a stream is reset.
//
// Measured over a real socket, one stalled call, ended two ways:
//
//   ended by draining it  -> the connection recovers
//   ended by cancelling   -> every later call on it HUNG, polled 20 s
//
// One cancel was enough (68 KiB reached the wire -- the HTTP/2 default
// connection window), in the upload and the download direction alike. And while
// the call was merely STALLED, unrelated calls on the same connection already
// hung, which is the sharper form of the same fact.
//
// So the pause is gone. The budget stays (flowControlWindowBytes), reading
// never stops, and a call past its window is FAILED instead of throttled. The
// cost, accepted by the owner: a consumer that stops consuming kills its own
// call. The bound itself is guarded by upload_backpressure_test and
// slow_reader_backpressure_test, which still pass on their original numbers.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _messageBytes = 4 * 1024;

/// Per-test state, so a handler left running by an earlier test cannot be
/// mistaken for this one's.
final class _Run {
  final Completer<void> gate = Completer<void>();
  int consumed = 0;
}

final class _Contract extends RpcResponderContract {
  _Contract(this.run) : super('Svc');

  final _Run run;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: (requests, {RpcContext? context}) async* {
        // Deaf until the gate opens, then it drains.
        await run.gate.future;
        await for (final _ in requests) {
          run.consumed++;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Firehose',
      handler: (r, {RpcContext? context}) async* {
        final chunk = ('y' * 16384).rpc;
        for (var i = 0; i < 40000; i++) {
          yield chunk;
          if (i % 50 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Ping',
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcHttp2Server server,
  RpcHttp2CallerTransport transport,
  RpcCallerEndpoint caller,
  _Run run,
});

Future<_Rig> _connect() async {
  final run = _Run();
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
  return (
    server: server,
    transport: transport,
    caller: RpcCallerEndpoint(transport: transport),
    run: run,
  );
}

Future<void> _teardown(_Rig rig) async {
  if (!rig.run.gate.isCompleted) rig.run.gate.complete();
  await rig.transport.close().catchError((Object _) {});
  await rig.server.stop();
}

/// Whether an unrelated call still works on this connection.
///
/// A dead pool never recovers, so a timeout here is the real observable and a
/// generous one costs nothing on the passing path.
Future<String> _ping(_Rig rig) async {
  try {
    final r = await rig.caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Ping',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 6));
    return r.value;
  } on TimeoutException {
    return 'HUNG';
  } catch (e) {
    return 'ERR $e';
  }
}

void main() {
  group('a stalled upload does not take the connection with it', () {
    test(
      'the connection still serves other calls during the stall',
      () async {
        // WITNESS. With the pause, this was HUNG: the stalled call had parked the
        // whole connection window.
        final rig = await _connect();
        expect(await _ping(rig), 'pong', reason: 'baseline');

        final body = 'x' * _messageBytes;
        Stream<RpcString> requests() async* {
          for (var i = 0; i < 40000; i++) {
            yield body.rpc;
            if (i % 50 == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          }
        }

        final sub = rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Chat',
              requests: requests(),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen((_) {}, onError: (Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 800));

        expect(
          await _ping(rig),
          'pong',
          reason:
              'a call stalled on a deaf handler blocked the whole connection',
        );

        await sub.cancel();
        await _teardown(rig);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'and still serves them after the stalled call is cancelled',
      () async {
        // WITNESS. With the pause this stayed HUNG for good -- the pool was
        // discarded uncredited by the reset, so nothing ever came back.
        final rig = await _connect();
        expect(await _ping(rig), 'pong', reason: 'baseline');

        final body = 'x' * _messageBytes;
        Stream<RpcString> requests() async* {
          for (var i = 0; i < 40000; i++) {
            yield body.rpc;
            if (i % 50 == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          }
        }

        final sub = rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Chat',
              requests: requests(),
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen((_) {}, onError: (Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          await _ping(rig),
          'pong',
          reason:
              'cancelling one stalled upload left the connection unusable for '
              'every later call',
        );

        await _teardown(rig);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('a paused download does not take the connection with it', () {
    test(
      'the connection survives a paused-then-cancelled download',
      () async {
        // WITNESS for the mirror direction: the same code hop lives in the caller
        // transport, and it failed the same way -- here it is the client's own
        // inbound pool, so the server cannot send the ping's response.
        final rig = await _connect();
        expect(await _ping(rig), 'pong', reason: 'baseline');

        final sub = rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Firehose',
              request: 'go'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen((_) {}, onError: (Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 300));
        sub.pause();
        await Future<void>.delayed(const Duration(milliseconds: 800));

        expect(
          await _ping(rig),
          'pong',
          reason: 'a paused download blocked the whole connection',
        );

        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          await _ping(rig),
          'pong',
          reason:
              'cancelling one paused download left the connection unusable for '
              'every later call',
        );

        await _teardown(rig);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'GUARD: an ordinary drained call is unaffected',
      () async {
        // The paired "a valid case is not refused": nothing about failing a
        // stalled call may touch a call that reads what it asked for.
        final rig = await _connect();
        final got = await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Firehose',
              request: 'go'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .take(200)
            .toList()
            .timeout(const Duration(seconds: 30));
        expect(got, hasLength(200));
        expect(await _ping(rig), 'pong');
        await _teardown(rig);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
