// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request whose body never arrived parked a responder stream for 60s.
//
// The transport emitted the opening metadata frame BEFORE reading the body, so
// a peer that sent gRPC headers and then went silent had already opened a
// pipeline stream. Its error path removes the transport's own `_pending` entry
// and nothing else, so the pipeline held the stream until `halfOpenStreamTimeout`
// (60s by default) reclaimed it.
//
// `bodyReadTimeout` is what the docs point at for exactly this attack, and it
// worked on the transport's side only. Measured, 8 aborted requests against
// `maxActiveStreams: 8` with the mitigation ON:
//
//   pendingRequests      0        <- released at 408, as documented
//   openStreams          8 -> 0
//   an ordinary call     RpcStatusException(8) -> OK
//
// RpcHttpServer keeps ONE RpcResponderEndpoint for the whole server, so those
// streams are a budget every client shares: one peer wedged all of them.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _maxActiveStreams = 4;
const Duration _bodyReadTimeout = Duration(seconds: 2);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

typedef _Rig = ({
  RpcHttpResponderTransport transport,
  RpcResponderEndpoint endpoint,
  RpcCallerEndpoint caller,
  int port,
});

Future<_Rig> _serve() async {
  final transport = RpcHttpResponderTransport(
    securityPolicy: const RpcSecurityPolicy(
      maxActiveStreams: _maxActiveStreams,
    ),
    bodyReadTimeout: _bodyReadTimeout,
  );
  final endpoint = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_Svc())
    ..start();
  final httpServer = await shelf_io.serve(transport.handler, '127.0.0.1', 0);

  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${httpServer.port}',
    ),
  );
  addTearDown(() async {
    await caller.close();
    await endpoint.close();
    await httpServer.close(force: true);
  });
  return (
    transport: transport,
    endpoint: endpoint,
    caller: caller,
    port: httpServer.port,
  );
}

int _openStreams(RpcResponderEndpoint e) =>
    e.collectResponderMetrics()['openStreams']! as int;

Future<int> _pendingRequests(RpcHttpResponderTransport t) async =>
    (await t.health()).details['pendingRequests']! as int;

/// Sends gRPC request headers promising a body, then dies mid-body.
Future<void> _abortMidBody(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.write(
    'POST /Svc/echo HTTP/1.1\r\n'
    'host: 127.0.0.1:$port\r\n'
    'content-type: application/grpc\r\n'
    'content-length: 100000\r\n'
    '\r\n',
  );
  // Five bytes: a gRPC length prefix promising four more that never arrive.
  socket.add(const <int>[0, 0, 0, 0, 4]);
  await socket.flush();
  socket.destroy();
}

/// Polls [read] until it returns [want], or gives up after [budget].
Future<int> _until(
  Future<int> Function() read,
  int want,
  Duration budget,
) async {
  final deadline = DateTime.now().add(budget);
  var value = await read();
  while (value != want && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    value = await read();
  }
  return value;
}

/// The highest value [read] reports over [budget].
///
/// The rise-check below needs "did these requests reach the transport at all",
/// and asking for a SIMULTANEOUS count is a stronger question than that. It
/// flaked in a loaded full-suite run -- `Expected: <4> Actual: <0>` -- because
/// the sockets are opened one at a time and `bodyReadTimeout` can answer the
/// first before the last one connects, so the count never reaches 4 at any
/// single instant. A peak is what the guard actually means.
///
/// A peak is only meaningful over a window that CONTAINS the event, which is
/// why the caller starts this before the aborts rather than after them. That
/// second flake reads identically to the first -- `Actual: <0>` -- and has a
/// different cause, so fixing the question without fixing the window left it
/// live.
///
/// Starts by polling immediately, so a rise that has already happened when the
/// budget opens is still seen.
Future<int> _peak(Future<int> Function() read, Duration budget) async {
  final deadline = DateTime.now().add(budget);
  var peak = 0;
  while (DateTime.now().isBefore(deadline)) {
    final value = await read();
    if (value > peak) peak = value;
    if (value == 0 && peak > 0) break; // risen and settled; nothing more to see
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return peak;
}

Future<RpcString> _echo(RpcCallerEndpoint caller) =>
    caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'hi'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

void main() {
  test(
    'a body that never arrives leaves no stream in the pipeline',
    () async {
      // WITNESS. Pre-fix: openStreams stayed at 4 and the call below failed
      // RESOURCE_EXHAUSTED until the 60s half-open reclaim.
      final rig = await _serve();

      // The observation starts BEFORE the aborts, and that ordering is the
      // whole point. `_abortMidBody` destroys its socket the moment the headers
      // are out, so a request can be answered by a read ERROR — promptly —
      // rather than by bodyReadTimeout two seconds later. Which of the two
      // happens is TCP and scheduling, so polling only after the loop makes the
      // rise a coin toss: on a loaded machine all four can be answered before
      // the first poll, and the guard reads 0 on a server that did everything
      // right.
      final peak = _peak(
        () => _pendingRequests(rig.transport),
        const Duration(seconds: 8),
      );

      for (var i = 0; i < _maxActiveStreams; i++) {
        await _abortMidBody(rig.port);
      }

      // The RISE: without it, "openStreams == 0" would also pass on a server
      // the aborted requests never reached. A PEAK, not a simultaneous count --
      // see [_peak] for what that cost.
      expect(
        await peak,
        greaterThan(0),
        reason: 'the aborted requests must reach the transport at all',
      );

      // Then for bodyReadTimeout to answer them all with 408.
      expect(
        await _until(
          () => _pendingRequests(rig.transport),
          0,
          _bodyReadTimeout * 3,
        ),
        0,
        reason: 'bodyReadTimeout must release the transport budget',
      );

      expect(
        _openStreams(rig.endpoint),
        0,
        reason: 'and it must leave nothing parked in the pipeline either',
      );
      expect(
        (await _echo(rig.caller).timeout(const Duration(seconds: 10))).value,
        'hi',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary call still works, and clears up after itself',
    () async {
      // Without this the witness would pass on a transport that never emitted
      // an opening frame at all.
      final rig = await _serve();

      expect(
        (await _echo(rig.caller).timeout(const Duration(seconds: 10))).value,
        'hi',
      );
      expect(
        await _until(
          () => Future<int>.value(_openStreams(rig.endpoint)),
          0,
          const Duration(seconds: 5),
        ),
        0,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
