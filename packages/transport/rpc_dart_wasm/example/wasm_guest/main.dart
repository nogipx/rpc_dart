// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A REAL dart2wasm guest, compiled by tool/build_guest.sh and loaded by the
// integration tests.
//
// Everything else on the device runs plain JS through the raw bridge, which
// proves the byte pipe and nothing above it. This is the only thing that puts
// rpc_dart's own stack -- framing, flow control, contracts -- inside the
// sandbox, which is what an application actually does.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

/// Items the Firehose handler has yielded, readable over RPC.
int _produced = 0;

/// What a caller of [RpcWasm.run] sees when `configure` throws.
///
/// The boot runs inside `runZonedGuarded`, and a SYNCHRONOUS throw out of a
/// zone body goes to the zone handler rather than to the caller — so `run`
/// returned through a `late final` that was never assigned and raised
/// `LateInitializationError`, hiding the real cause. Recorded here on the way
/// past and read back over RPC by the integration test, because this is the
/// only place the real dart2wasm boot path actually runs.
String _bootFailureSeen = 'not attempted';

final class _EchoService extends RpcResponderContract {
  _EchoService() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Say',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async =>
          'echo:${request.value}'.rpc,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Big',
      requestCodec: _codec,
      responseCodec: _codec,
      // Returns as many bytes as asked for, so a caller can drive the response
      // across the host's transport ceilings from inside the guest.
      handler: (request, {RpcContext? context}) async =>
          ('x' * int.parse(request.value)).rpc,
    );

    // Unbounded, so a caller can cancel mid-flight. `_produced` is readable
    // through Produced below, which is how the host asks whether the handler
    // actually STOPPED rather than merely stopped being listened to.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Firehose',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        final body = 'y' * 1024;
        while (true) {
          yield body.rpc;
          _produced++;
          await Future<void>.delayed(Duration.zero);
        }
      },
    );

    // Drops a failing Future on the floor, the way ordinary guest code does by
    // accident. Nothing awaits it, so it can only surface as an unhandled
    // async error.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Orphan',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async {
        Future<void>.delayed(
          const Duration(milliseconds: 50),
          () => throw StateError('orphaned guest failure'),
        );
        return 'scheduled'.rpc;
      },
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Produced',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async => '$_produced'.rpc,
    );

    // How long a guest Timer ACTUALLY takes, measured inside the guest.
    //
    // The host cannot measure this: a round trip through the bridge costs more
    // than the delays being measured, so timing it from outside reports the
    // transport rather than the timer. The guest clocks its own sleep and
    // returns the error in microseconds.
    //
    // The point is the WKWebView on iOS. It is never added to a view hierarchy,
    // so the page is permanently hidden, and WebKit throttles timers in hidden
    // pages. A guest whose Timers are delayed by seconds is a different product
    // from one whose Timers are accurate, and nothing in this repository has
    // ever measured which one this is.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'TimerLag',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async {
        final wanted = int.parse(request.value);
        final samples = <int>[];
        for (var i = 0; i < 10; i++) {
          final clock = Stopwatch()..start();
          await Future<void>.delayed(Duration(milliseconds: wanted));
          samples.add(clock.elapsedMicroseconds - wanted * 1000);
        }
        samples.sort();
        return '${samples.first},${samples[samples.length ~/ 2]},'
                '${samples.last}'
            .rpc;
      },
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'BootFailure',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async => _bootFailureSeen.rpc,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        final parts = <String>[];
        await for (final r in requests) {
          parts.add(r.value);
        }
        return '${parts.length}:${parts.join(",")}'.rpc;
      },
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Mirror',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield 'back:${r.value}'.rpc;
        }
      },
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Count',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        final n = int.parse(request.value);
        for (var i = 0; i < n; i++) {
          yield 'item-$i'.rpc;
        }
      },
    );
  }
}

void main() {
  // Deliberately fail the boot once, and record what the caller was given.
  // `_boot` closes the endpoint and clears `_initialized` on the way out, so
  // the real boot below is unaffected — which the whole suite then proves.
  try {
    RpcWasm.run(
      configure: (_) => throw StateError('configure exploded on purpose'),
    );
    _bootFailureSeen = 'no throw at all';
  } catch (error) {
    _bootFailureSeen = '${error.runtimeType}: $error';
  }

  RpcWasm.run(
    configure: (endpoint) {
      endpoint.registerServiceContract(_EchoService());
    },
  );
}
