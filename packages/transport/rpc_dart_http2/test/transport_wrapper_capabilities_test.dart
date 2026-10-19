// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2Server.transportWrapper lets an application substitute the transport
// the endpoint sees, and the server uses what it returns as is. The endpoint
// layers read the security policy and the flow-control credit off that
// transport, so a decorator keeps them only by forwarding them -- and a
// decorator that `implements IRpcTransport` must, because every member is
// abstract to it and a forgotten one does not compile.
//
// These cases run a forwarding decorator against a server capped at
// `maxActiveStreams: 3`, with a peer opening 60 concurrent streams, and against
// a deaf client-stream handler behind a 4 MiB window. A decorator that
// overrides the policy instead of forwarding it gets its own.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
Completer<void> _gate = Completer<void>();

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'park',
      handler: (request, {RpcContext? context}) async {
        await _gate.future;
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Forwards every [IRpcTransport] member -- what a metrics or auth decorator
/// looks like when written the obvious way.
class _CountingTransport implements IRpcTransport {
  _CountingTransport(this.inner);
  final IRpcTransport inner;
  int metadataSends = 0;

  @override
  bool get isClient => inner.isClient;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get supportsZeroCopy => inner.supportsZeroCopy;
  @override
  Stream<RpcTransportMessage> get incomingMessages => inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      inner.getMessagesForStream(id);
  @override
  int createStream() => inner.createStream();
  @override
  bool releaseStreamId(int id) => inner.releaseStreamId(id);
  @override
  Future<void> sendMetadata(int id, RpcMetadata m, {bool endStream = false}) {
    metadataSends++;
    return inner.sendMetadata(id, m, endStream: endStream);
  }

  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      inner.sendMessage(id, d, endStream: endStream);
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      inner.sendDirectObject(id, o, endStream: endStream);
  @override
  Future<void> finishSending(int id) => inner.finishSending(id);
  @override
  Future<RpcHealthStatus> health() => inner.health();
  @override
  Future<void> close() => inner.close();
  @override
  int get lastIssuedStreamId => inner.lastIssuedStreamId;
  @override
  void resumeStreamIdsAfter(int streamId) =>
      inner.resumeStreamIdsAfter(streamId);
  @override
  RpcSecurityPolicy get securityPolicy => inner.securityPolicy;
  @override
  Future<void> get ready => inner.ready;
  @override
  Future<bool> resetStream(int streamId, {String? reason}) =>
      inner.resetStream(streamId, reason: reason);
  @override
  IRpcFlowCredit? get flowCredit => inner.flowCredit;
  @override
  bool get grantsMessageCredit => inner.grantsMessageCredit;
  @override
  IRpcConnectionBuffer? get connectionBuffer => inner.connectionBuffer;
}

/// A decorator that deliberately declares its own, different, policy. The
/// server must use it as it is.
class _OpinionatedTransport extends _CountingTransport {
  _OpinionatedTransport(super.inner);

  @override
  RpcSecurityPolicy get securityPolicy =>
      const RpcSecurityPolicy(maxActiveStreams: 11);
}

/// Forwards each flow-credit call to the inner transport's credit.
final class _ForwardingFlowCredit implements IRpcFlowCredit {
  _ForwardingFlowCredit(this.inner);
  final IRpcFlowCredit inner;

  @override
  void deferFlowCredit(int streamId) => inner.deferFlowCredit(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      inner.returnFlowCredit(streamId, bytes);
}

/// Hands out its own flow-credit object that forwards to the inner one -- a
/// decorator that meters the credit on its way through.
class _ForwardingFlowTransport extends _CountingTransport {
  _ForwardingFlowTransport(super.inner);

  @override
  IRpcFlowCredit? get flowCredit {
    final credit = inner.flowCredit;
    return credit == null ? null : _ForwardingFlowCredit(credit);
  }
}

final class _UploadRun {
  final Completer<void> gate = Completer<void>();
}

final class _UploadContract extends RpcResponderContract {
  _UploadContract(this.run) : super('Svc');
  final _UploadRun run;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        await run.gate.future; // consumes nothing
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Counts client->server bytes by relaying raw TCP, so the HTTP/2 framing
/// passes through untouched. Measure the WIRE, not the sender: the caller's
/// sends are fire-and-forget, so counting what it produced hides the bound.
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

/// The threshold the upload tests assert against, shared with [_upload] so its
/// early exit uses the same number the expectation does — otherwise the two
/// could drift and the poll would stop at a figure the test still passes.
const int _uploadCeilingBytes = 8 * 1024 * 1024;

/// Uploads into a handler that consumes nothing and returns the bytes that
/// reached the server.
Future<int> _upload(IRpcTransport Function(IRpcTransport inner)? wrap) async {
  final state = _UploadRun();
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    transportWrapper: wrap == null ? null : (inner, _) => wrap(inner),
    mode: RpcResponderMode(
      (e) => e.registerServiceContract(_UploadContract(state)),
    ),
  );
  await server.start();
  final relay = _Relay();
  final port = await relay.start(server.port);
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: port,
  );
  final caller = RpcCallerEndpoint(transport: client);

  final body = 'x' * (4 * 1024);
  Stream<RpcString> requests() async* {
    for (var i = 0; i < 40000; i++) {
      yield body.rpc;
      // Paced, so window updates have time to matter. Pacing can only reduce
      // what is offered, never cause a false pass.
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

  // A flat 8 s wait here cost this file 4 x ~8 s of every run. The budget is
  // still 8 s -- long enough that steady growth cannot be mistaken for a
  // ceiling, which is what it was chosen for -- but two outcomes are decided
  // before it expires and neither
  // weakens the assertion:
  //
  //   PLATEAU  the wire count stops moving => the bound engaged, and waiting
  //            longer cannot change a number that is no longer changing.
  //   BREACH   the count is already past the threshold the test asserts, so
  //            the verdict is settled and only the failure is being delayed.
  //
  // Anything still climbing below the threshold gets the whole 8 s, which is
  // the case the duration was for.
  // The plateau needs a FLOOR under it. A first cut called 0.9 s of no movement
  // a plateau and exited at 1.8-2.4 MiB, while the bounded steady state this
  // file documents is 4176 KiB -- it was stopping mid-ramp, during a lull in
  // the 1 ms-per-50-messages pacing, and a test that measures less of the curve
  // is not a faster test, it is a weaker one. So: nothing counts as settled
  // before `settleFloor`, and the stillness has to last `plateauSamples`.
  const budget = Duration(seconds: 8);
  const settleFloor = Duration(seconds: 3);
  const sample = Duration(milliseconds: 150);
  const plateauSamples = 10; // 1.5 s of no movement
  final start = DateTime.now();
  final deadline = start.add(budget);
  final floor = start.add(settleFloor);
  var last = -1;
  var still = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(sample);
    final now = relay.bytes;
    if (now >= _uploadCeilingBytes) break; // BREACH: the verdict is settled
    if (now == last) {
      still++;
      if (still >= plateauSamples && DateTime.now().isAfter(floor)) {
        break; // PLATEAU
      }
    } else {
      still = 0;
      last = now;
    }
  }
  final seen = relay.bytes;

  state.gate.complete();
  await client.close().catchError((Object _) {});
  await server.stop();
  await relay.stop();
  return seen;
}

/// Runs 60 concurrent parked calls against a server capped at 3 and reports
/// what the responder admitted.
Future<({int open, IRpcTransport transport, _CountingTransport? wrapper})> _run(
  IRpcTransport Function(IRpcTransport inner)? wrap,
) async {
  _CountingTransport? built;
  RpcResponderEndpoint? serverEndpoint;

  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    policy: const RpcSecurityPolicy(maxActiveStreams: 3),
    transportWrapper: wrap == null
        ? null
        : (inner, _) {
            final w = wrap(inner);
            if (w is _CountingTransport) built = w;
            return w;
          },
    mode: RpcResponderMode((endpoint) {
      serverEndpoint = endpoint;
      endpoint.registerServiceContract(_Contract());
    }),
  );
  await server.start();

  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
    // Permissive, so the ceiling under test is the server's.
    policy: const RpcSecurityPolicy(maxActiveStreams: 100000),
  );
  final caller = RpcCallerEndpoint(transport: client);

  final calls = <Future<Object>>[
    for (var i = 0; i < 60; i++)
      caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'park',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then<Object>((r) => r, onError: (Object e) => e),
  ];
  await Future<void>.delayed(const Duration(seconds: 2));

  final open = serverEndpoint!.collectEndpointMetrics()['openStreams'] as int;
  final transport = serverEndpoint!.transport;

  _gate.complete();
  // Teardown, not measurement: `open` was read above and is the only thing
  // this returns about admission. The 10 s this used to allow ALWAYS expired
  // (measured 10.1 s in every one of the four cases) because the refused calls
  // never all settle, so it was 10 s of dead time per case buying nothing.
  await Future.wait(
    calls,
  ).timeout(const Duration(seconds: 1), onTimeout: () => const []);
  await caller.close();
  await client.close();
  await server.stop();

  return (open: open, transport: transport, wrapper: built);
}

void main() {
  setUp(() => _gate = Completer<void>());
  tearDown(() {
    if (!_gate.isCompleted) _gate.complete();
  });

  test('CONTROL: with no wrapper the ceiling holds', () async {
    final r = await _run(null);
    expect(r.open, lessThanOrEqualTo(3));
    expect(r.transport.securityPolicy.maxActiveStreams, 3);
  });

  test('a wrapper that forwards every member keeps the ceiling', () async {
    final r = await _run(_CountingTransport.new);
    expect(
      r.open,
      lessThanOrEqualTo(3),
      reason:
          'the decorator did not carry the policy through, so the pipeline '
          'fell back to the default ceiling and admitted every stream',
    );
    expect(r.transport, same(r.wrapper));
    expect(r.transport.securityPolicy.maxActiveStreams, 3);
  });

  test('the wrapper is the one doing the work', () async {
    // GUARD: the endpoint must use the decorator itself, not route calls
    // around it -- that would still cap streams, while silently disabling
    // whatever the wrapper was written to do.
    final r = await _run(_CountingTransport.new);
    expect(r.wrapper, isNotNull);
    expect(
      r.wrapper!.metadataSends,
      greaterThan(0),
      reason: 'responses must still travel through the decorator',
    );
  });

  test('a wrapper with its own policy is left alone', () async {
    // GUARD: overriding securityPolicy is how a decorator says "I mean a
    // different policy", so it must win over the inner one.
    final r = await _run(_OpinionatedTransport.new);
    expect(r.transport.securityPolicy.maxActiveStreams, 11);
    expect(r.open, greaterThan(3));
  });

  group('the upload bound survives the wrapper', () {
    // The other capability, and the one with no ceiling behind it. The inner
    // transport is the only object that sees bytes ARRIVE, so it is the only
    // one that can charge them -- and it only charges a stream it has been told
    // is pipeline-fed, through the flowCredit the endpoint reads off the
    // decorator. A deaf client-stream handler behind a 4 MiB window must
    // therefore stay bounded on the WIRE whether the decorator forwards the
    // inner credit object or hands out its own that forwards to it.
    for (final shape in const ['none', 'plain', 'forwards']) {
      test(
        '$shape: a deaf handler still bounds the upload',
        () async {
          final r = await _upload(switch (shape) {
            'plain' => _CountingTransport.new,
            'forwards' => _ForwardingFlowTransport.new,
            _ => null,
          });
          expect(
            r,
            lessThan(_uploadCeilingBytes),
            reason:
                '${(r / 1024 / 1024).toStringAsFixed(1)} MiB reached a server '
                'whose handler consumed nothing, against a 4 MiB window',
          );
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    }
  });
}
