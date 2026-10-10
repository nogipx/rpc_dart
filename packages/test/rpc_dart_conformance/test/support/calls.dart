// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller side of a row: start a call of one shape, cancel it the way that
// shape is cancelled, and read how it ended. Plus the Probe that collects the
// handler's events.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'contract.dart';

/// The four call shapes.
enum CallShape { unary, clientStream, serverStream, bidi }

var _nextId = 1;

/// A call id unique in this test process. Events are keyed by it.
int nextCallId() => _nextId++;

/// How a call ended.
final class Outcome {
  Outcome.value(this.responses) : error = null;
  Outcome.error(Object this.error) : responses = const [];

  final List<Blob> responses;
  final Object? error;

  bool get ok => error == null;

  /// 0 for success, the status code of an [RpcStatusException], or -1 for an
  /// error that carries no status.
  int get status {
    final e = error;
    if (e == null) return RpcStatus.ok;
    if (e is RpcStatusException) return e.statusCode;
    return -1;
  }

  @override
  String toString() => ok
      ? 'ok (${responses.length} responses)'
      : 'status $status: ${error.runtimeType}: $error';
}

/// One call in flight.
final class Call {
  /// Starts a call of [shape] whose first request is [request].
  ///
  /// [deadline] puts a deadline on the context. [keepRequestsOpen] leaves the
  /// request stream of a client-stream or bidi call open, so the call cannot
  /// finish on its own. [pauseResponses] pauses a streamed response from the
  /// moment the call is listened to. [headers] travel as call metadata.
  Call.start(
    ConformanceCaller caller,
    this.shape,
    Blob request, {
    Duration? deadline,
    bool keepRequestsOpen = false,
    Duration? pauseResponses,
    Map<String, String> headers = const {},
    void Function(Blob response)? onResponse,
  }) {
    var context = RpcContext.withHeaders(headers).withCancellation(token);
    if (deadline != null) context = context.withTimeout(deadline);

    switch (shape) {
      case CallShape.unary:
        _settle(caller.unary(request, context: context).then((r) => [r]));
      case CallShape.clientStream:
        _requests.add(request);
        if (!keepRequestsOpen) _requests.close().ignore();
        _settle(
          caller
              .clientStream(_requests.stream, context: context)
              .then((r) => [r]),
        );
      case CallShape.serverStream:
        _listen(
          caller.serverStream(request, context: context),
          pauseResponses,
          onResponse,
        );
      case CallShape.bidi:
        _requests.add(request);
        if (!keepRequestsOpen) _requests.close().ignore();
        _listen(
          caller.bidi(_requests.stream, context: context),
          pauseResponses,
          onResponse,
        );
    }
  }

  final CallShape shape;
  final RpcCancellationToken token = RpcCancellationToken();
  final _requests = StreamController<Blob>();
  final _done = Completer<Outcome>();
  final _clock = Stopwatch()..start();
  StreamSubscription<Blob>? _sub;
  final _received = <Blob>[];

  /// How the call ended. Never completes with an error.
  Future<Outcome> get outcome => _done.future;

  /// Time from start to the end of the call, once it has ended.
  Duration get elapsed => _clock.elapsed;

  /// Responses received so far by a streamed call.
  List<Blob> get received => List.unmodifiable(_received);

  /// The subscription of a streamed call, for a test that pauses it.
  StreamSubscription<Blob>? get subscription => _sub;

  void _settle(Future<List<Blob>> result) {
    result.then(
      (r) => _finish(Outcome.value(r)),
      onError: (Object e) => _finish(Outcome.error(e)),
    );
  }

  void _listen(
    Stream<Blob> responses,
    Duration? pause,
    void Function(Blob response)? onResponse,
  ) {
    final sub = responses.listen(
      (r) {
        _received.add(r);
        onResponse?.call(r);
      },
      onError: (Object e) => _finish(Outcome.error(e)),
      onDone: () => _finish(Outcome.value(List.of(_received))),
      cancelOnError: true,
    );
    _sub = sub;
    if (pause != null) {
      sub.pause();
      Timer(pause, sub.resume);
    }
  }

  void _finish(Outcome outcome) {
    if (_done.isCompleted) return;
    _clock.stop();
    _done.complete(outcome);
    if (!_requests.isClosed) _requests.close().ignore();
  }

  /// Sends one more request on a client-stream or bidi call.
  void send(Blob request) => _requests.add(request);

  /// Ends the request stream of a client-stream or bidi call.
  void finishRequests() {
    if (!_requests.isClosed) _requests.close().ignore();
  }

  /// Cancels the call the way its shape is cancelled by an application: the
  /// context's token for a unary or client-stream call, the subscription for
  /// a server-stream or bidi call. The outcome of a cancelled subscription is
  /// recorded here, because a cancelled subscription reports nothing more.
  Future<void> cancel() async {
    switch (shape) {
      case CallShape.unary:
      case CallShape.clientStream:
        token.cancel('the caller cancels');
      case CallShape.serverStream:
      case CallShape.bidi:
        final sub = _sub;
        _finish(Outcome.error(RpcCancelledException('subscription cancelled')));
        await sub?.cancel();
    }
  }
}

/// Waits for [call] to end within [bound], failing the test with [what] if it
/// does not.
Future<Outcome> endsWithin(Call call, Duration bound, String what) =>
    call.outcome.timeout(
      bound,
      onTimeout: () => fail(
        '$what: the ${call.shape.name} call did not end within '
        '${bound.inMilliseconds} ms',
      ),
    );

/// One event reported by a handler.
final class ProbeEvent {
  const ProbeEvent(this.kind, this.id, this.n);
  final String kind;
  final int id;
  final int n;

  @override
  String toString() => '$kind#$id($n)';
}

/// Collects the handler's events, on whichever side of an isolate boundary
/// the handler runs.
final class Probe {
  final List<ProbeEvent> events = [];
  final _ctl = StreamController<ProbeEvent>.broadcast(sync: true);

  void emit(String kind, int id, int n) {
    final e = ProbeEvent(kind, id, n);
    events.add(e);
    _ctl.add(e);
  }

  bool has(String kind, int id) =>
      events.any((e) => e.kind == kind && e.id == id);

  int count(String kind, {int? id}) =>
      events.where((e) => e.kind == kind && (id == null || e.id == id)).length;

  /// Largest `n` reported for [kind] on call [id], or 0.
  int maxN(String kind, int id) => events
      .where((e) => e.kind == kind && e.id == id)
      .fold(0, (m, e) => e.n > m ? e.n : m);

  /// Waits for the handler of call [id] to report [kind], failing the test if
  /// it does not within [within].
  Future<void> waitFor(
    String kind,
    int id, {
    Duration within = const Duration(seconds: 2),
    String? because,
  }) async {
    if (has(kind, id)) return;
    await _ctl.stream
        .firstWhere((e) => e.kind == kind && e.id == id)
        .timeout(
          within,
          onTimeout: () => fail(
            'the handler of call $id never reported "$kind" within '
            '${within.inMilliseconds} ms${because == null ? '' : ' ($because)'}'
            '; it reported: ${events.where((e) => e.id == id).toList()}',
          ),
        );
  }

  /// Waits until [count] calls have reported [kind].
  Future<void> waitForCount(
    String kind,
    int count, {
    Duration within = const Duration(seconds: 2),
  }) async {
    if (this.count(kind) >= count) return;
    await _ctl.stream
        .where((e) => e.kind == kind)
        .firstWhere((_) => this.count(kind) >= count)
        .timeout(
          within,
          onTimeout: () => fail(
            'only ${this.count(kind)} of $count handlers reported "$kind" '
            'within ${within.inMilliseconds} ms',
          ),
        );
  }
}

/// Polls [read] until [done] holds, failing with [what] after [within].
///
/// For gauges only, and only after the rise has been seen: an event at the
/// peer is asserted with [Probe.waitFor] instead.
Future<T> pollUntil<T>(
  Future<T> Function() read,
  bool Function(T value) done, {
  required String what,
  Duration within = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(within);
  while (true) {
    final value = await read();
    if (done(value)) return value;
    if (DateTime.now().isAfter(deadline)) {
      fail('$what: still $value after ${within.inMilliseconds} ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
