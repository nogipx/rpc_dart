// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The lifecycle model -- random sequences of call operations on ONE
// connection, checked against a model after every step.
//
// A sequence is generated from a seed by a model that knows only what it did:
// start a call of a shape and a handler behaviour (answer at once, answer
// late, throw, hang), with or without a deadline and with the request stream
// left open or not; send one more request; half-close; pause and resume a
// response stream; cancel through the token or the subscription; let time
// pass; close the caller endpoint. The sequence does not depend on what the
// real code answered, so a seed is the whole sequence on every run.
//
// After every step, and after a drain that resumes, half-closes and waits for
// every call:
//   - every call that has ended ended exactly once: no second error, no
//     response after the end, and each handler entered, was disposed and
//     released its timer at most once;
//   - every call ends within its earliest trigger (deadline, cancel, endpoint
//     close, the handler's own answer) + 1 s, a paused stream counting from
//     its resume (I-1);
//   - nothing escapes as an uncaught async error (I-4);
// and at the end:
//   - every handler that entered was disposed and released its timer, and the
//     gauges the I-5 row reads are back at baseline on both sides (I-5),
//     but for the server's `fc.*` on channel and isolate (lead B-279);
//   - a call nothing interfered with ends the way its handler and deadline
//     say, when the two are at least [_margin] apart.
//
// A failing sequence is shrunk (operations removed while the same property
// still fails) and printed with the command that replays it. A shrunk
// sequence worth keeping is pinned in [_pinned] and runs on every member.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

/// Seeds every member runs.
final _seeds = [for (var s = 1; s <= 12; s++) s];

/// Operations per sequence.
const _length = 40;

/// What I-1 allows past a call's earliest trigger.
const _slack = Duration(seconds: 1);

/// How far apart a handler's answer and a deadline must be for the model to
/// predict which one ends the call.
const _margin = Duration(milliseconds: 150);

/// Most re-runs a shrink spends.
const _shrinkRuns = 60;

/// An operation sequence to replay, in the format a failure prints.
const _replayEnv = 'LIFECYCLE_OPS';

const _notAGauge = {'transport.finishedStreams'};
const _registrations = {'registeredContracts', 'registeredMethods'};

/// Sequences a seed once produced, kept because they fail somewhere: a seed
/// stops producing its sequence the moment the generator changes.
const _pinned = {
  'send after the handler failed, response paused':
      'start c0 bidi fail delay=17 count=3 deadline=none open; pause c0; '
      'wait 52; send c0',
};

const _knownFailing = <String, String>{
  'http2 | pinned send after the handler failed, response paused':
      'the call ends with status 9 "Stream 3 not found. Send metadata '
      'first." instead of the handler\'s ABORTED',
};

void main() {
  group('Lifecycle model, random operations on one connection:', () {
    for (final seed in _seeds) {
      for (final member in members) {
        _cell(member, 'seed $seed', () => _generate(seed));
      }
    }
    for (final MapEntry(key: name, value: ops) in _pinned.entries) {
      for (final member in members) {
        _cell(member, 'pinned $name', () => _parse(ops));
      }
    }
  });

  final replay = Platform.environment[_replayEnv];
  if (replay != null) {
    group('Lifecycle model, replay of $_replayEnv:', () {
      for (final member in members) {
        _cell(member, 'replay', () => _parse(replay));
      }
    });
  }
}

void _cell(Member member, String detail, List<_Op> Function() sequence) {
  cell(
    member,
    detail,
    knownFailing: _knownFailing,
    timeout: const Duration(minutes: 3),
    () async {
      final ops = sequence();
      final first = await _run(member, ops);
      if (first == null) return;
      final (minimal, last, runs) = await _shrink(member, ops, first);
      final name = '${member.name} | $detail';
      final text = minimal.join('; ');
      const dir = 'cd packages/test/rpc_dart_conformance &&';
      const file = 'test/lifecycle_model_test.dart';
      fail(
        '$name: $first\n'
        'shrunk from ${ops.length} to ${minimal.length} operations '
        '($runs runs), failing with: $last\n'
        '${[for (var i = 0; i < minimal.length; i++) '  $i. ${minimal[i]}'].join('\n')}\n'
        'replay the shrunk sequence:\n'
        "  $dir $_replayEnv='$text' fvm dart test $file "
        "-n '${member.name} \\| replay\$'\n"
        'replay this cell:\n'
        "  $dir fvm dart test $file --run-skipped -n '${member.name} \\| "
        "${detail.replaceAll('|', r'\|')}\$'",
      );
    },
  );
}

// ------------------------------------------------------------- operations --

sealed class _Op {
  const _Op();

  /// The call (the index of its start) this operation acts on, or null.
  int? get call => null;
}

final class _Start extends _Op {
  const _Start(
    this.call, {
    required this.shape,
    required this.mode,
    required this.delayMs,
    required this.count,
    required this.deadlineMs,
    required this.open,
  });

  @override
  final int call;
  final CallShape shape;
  final Mode mode;
  final int delayMs;
  final int count;
  final int? deadlineMs;

  /// The request stream stays open after the first request.
  final bool open;

  bool get streamsRequests =>
      shape == CallShape.clientStream || shape == CallShape.bidi;

  bool get streamsResponses =>
      shape == CallShape.serverStream || shape == CallShape.bidi;

  @override
  String toString() =>
      'start c$call ${shape.name} ${mode.name} delay=$delayMs count=$count '
      'deadline=${deadlineMs ?? 'none'}${open ? ' open' : ''}';
}

final class _Send extends _Op {
  const _Send(this.call);
  @override
  final int call;
  @override
  String toString() => 'send c$call';
}

final class _HalfClose extends _Op {
  const _HalfClose(this.call);
  @override
  final int call;
  @override
  String toString() => 'half-close c$call';
}

final class _Pause extends _Op {
  const _Pause(this.call);
  @override
  final int call;
  @override
  String toString() => 'pause c$call';
}

final class _Resume extends _Op {
  const _Resume(this.call);
  @override
  final int call;
  @override
  String toString() => 'resume c$call';
}

final class _Cancel extends _Op {
  const _Cancel(this.call, {required this.viaToken});
  @override
  final int call;

  /// Through the context's token; otherwise by cancelling the subscription.
  final bool viaToken;

  @override
  String toString() => 'cancel c$call ${viaToken ? 'token' : 'subscription'}';
}

final class _Wait extends _Op {
  const _Wait(this.ms);
  final int ms;
  @override
  String toString() => 'wait $ms';
}

final class _CloseEndpoint extends _Op {
  const _CloseEndpoint();
  @override
  String toString() => 'close-endpoint';
}

/// Reads a sequence in the format [_Op.toString] writes, `; `-separated.
List<_Op> _parse(String text) => [
  for (final part in text.split(';'))
    if (part.trim().isNotEmpty) _parseOne(part.trim().split(RegExp(r'\s+'))),
];

_Op _parseOne(List<String> t) {
  int call() => int.parse(t[1].substring(1));
  switch (t[0]) {
    case 'start':
      final kv = {
        for (final x in t.skip(4))
          if (x.contains('=')) x.split('=')[0]: x.split('=')[1],
      };
      return _Start(
        call(),
        shape: CallShape.values.byName(t[2]),
        mode: Mode.values.byName(t[3]),
        delayMs: int.parse(kv['delay']!),
        count: int.parse(kv['count']!),
        deadlineMs: kv['deadline'] == 'none'
            ? null
            : int.parse(kv['deadline']!),
        open: t.contains('open'),
      );
    case 'send':
      return _Send(call());
    case 'half-close':
      return _HalfClose(call());
    case 'pause':
      return _Pause(call());
    case 'resume':
      return _Resume(call());
    case 'cancel':
      return _Cancel(call(), viaToken: t[2] == 'token');
    case 'wait':
      return _Wait(int.parse(t[1]));
    case 'close-endpoint':
      return const _CloseEndpoint();
  }
  throw FormatException('unknown operation', t.join(' '));
}

// -------------------------------------------------------------- generator --

/// What the generator knows about a call: only what it did to it.
final class _ModelCall {
  _ModelCall(this.start) : open = start.open;
  final _Start start;
  bool open;
  bool paused = false;
  bool cancelled = false;
}

/// The sequence of [seed]: a pure function of the seed.
List<_Op> _generate(int seed) {
  final rng = Random(seed);
  int between(int lo, int hi) => lo + rng.nextInt(hi - lo + 1);
  T pick<T>(List<T> from) => from[rng.nextInt(from.length)];

  final ops = <_Op>[];
  final calls = <_ModelCall>[];
  var closed = false;

  _Op start() {
    final shape = pick(CallShape.values);
    final mode = switch (rng.nextInt(10)) {
      < 3 => Mode.echo,
      < 6 => Mode.hold,
      < 8 => Mode.fail,
      _ => Mode.hang,
    };
    final op = _Start(
      calls.length,
      shape: shape,
      mode: mode,
      delayMs: switch (mode) {
        Mode.hold => between(10, 120),
        Mode.fail => between(0, 80),
        _ => 0,
      },
      count: between(1, 3),
      // A hanging handler ends only through its deadline when nothing else
      // ends it, so it always has one.
      deadlineMs: mode == Mode.hang || rng.nextBool() ? between(40, 200) : null,
      open:
          (shape == CallShape.clientStream || shape == CallShape.bidi) &&
          rng.nextBool(),
    );
    calls.add(_ModelCall(op));
    return op;
  }

  while (ops.length < _length) {
    final live = calls.where((c) => !c.cancelled).toList();
    final open = live.where((c) => c.open).toList();
    final unpaused = live
        .where((c) => c.start.streamsResponses && !c.paused)
        .toList();
    final paused = calls.where((c) => c.paused).toList();

    final choices = <(int, _Op Function())>[
      (25, start),
      if (open.isNotEmpty) (12, () => _Send(pick(open).start.call)),
      if (open.isNotEmpty)
        (
          8,
          () {
            final c = pick(open)..open = false;
            return _HalfClose(c.start.call);
          },
        ),
      if (unpaused.isNotEmpty)
        (
          6,
          () {
            final c = pick(unpaused)..paused = true;
            return _Pause(c.start.call);
          },
        ),
      if (paused.isNotEmpty)
        (
          8,
          () {
            final c = pick(paused)..paused = false;
            return _Resume(c.start.call);
          },
        ),
      if (live.isNotEmpty)
        (
          8,
          () {
            final c = pick(live)
              ..cancelled = true
              ..open = false;
            final viaToken = !c.start.streamsResponses || rng.nextBool();
            if (!viaToken) c.paused = false;
            return _Cancel(c.start.call, viaToken: viaToken);
          },
        ),
      (20, () => _Wait(between(5, 40))),
      if (!closed)
        (
          1,
          () {
            closed = true;
            return const _CloseEndpoint();
          },
        ),
    ];
    var roll = rng.nextInt(choices.fold(0, (s, c) => s + c.$1));
    for (final (weight, make) in choices) {
      if (roll < weight) {
        ops.add(make());
        break;
      }
      roll -= weight;
    }
  }
  return ops;
}

// --------------------------------------------------------------- the run --

/// A property that did not hold.
final class _Violation {
  _Violation(this.kind, this.message, this.step, this.op);
  final String kind;
  final String message;

  /// Index of the operation after which it was seen; the length of the
  /// sequence for the drain.
  final int step;
  final _Op? op;

  @override
  String toString() =>
      '[$kind] $message (seen ${op == null ? 'in the drain' : 'after step $step: $op'})';
}

/// One call against the real code.
final class _Live {
  _Live(this.op, this.id, this.startedAt);
  final _Start op;
  final int id;
  final Duration startedAt;
  final token = RpcCancellationToken();
  final requests = StreamController<Blob>();
  StreamSubscription<Blob>? sub;

  int sent = 1;
  Duration? halfClosedAt;
  Duration? cancelledAt;
  bool cancelledSubscription = false;
  bool paused = false;
  Duration? resumedAt;

  Duration? endedAt;
  Object? error;
  int responses = 0;
  int errors = 0;
  int dones = 0;

  /// Exactly-once violations seen on the caller side.
  final List<String> twice = [];

  /// Set when the call ended after its I-1 bound.
  String? late;

  bool get ended => endedAt != null;

  String describe() {
    String at(Duration? d) => d == null ? '-' : '${d.inMilliseconds}';
    return 'c${op.call} (call id $id): $op; started ${at(startedAt)} ms, '
        'half-closed ${at(halfClosedAt)}, cancelled ${at(cancelledAt)}, '
        'resumed ${at(resumedAt)}${paused ? ', paused' : ''}, '
        'ended ${at(endedAt)} with '
        '${error == null ? 'ok ($responses responses)' : '$error'}';
  }
}

/// Runs [ops] against a fresh server of [member]; the first property that
/// fails, or null.
Future<_Violation?> _run(Member member, List<_Op> ops) {
  final result = Completer<_Violation?>();
  final uncaught = <String>[];
  runZonedGuarded(() async {
    try {
      result.complete(await _Run(member, ops, uncaught).execute());
    } catch (e, st) {
      result.complete(_Violation('harness', '$e\n$st', -1, null));
    }
  }, (Object e, StackTrace st) => uncaught.add('$e\n$st'));
  return result.future;
}

final class _Run {
  _Run(this.member, this.ops, this.uncaught);

  final Member member;
  final List<_Op> ops;
  final List<String> uncaught;

  final _clock = Stopwatch();
  final _calls = <int, _Live>{};
  late Rig _rig;
  late ConformanceCaller _caller;
  bool _dialled = false;
  Duration? _closedAt;
  Future<void>? _closing;
  bool _closeDone = false;
  int _step = 0;

  Duration get _now => _clock.elapsed;

  _Violation _violation(String kind, String message) =>
      _Violation(kind, message, _step, _step < ops.length ? ops[_step] : null);

  Future<_Violation?> execute() async {
    _rig = await member.serve();
    _Violation? found;
    try {
      found = await _body();
    } finally {
      // The caller goes first, so a server that drains its connections
      // gracefully has none left to wait for.
      if (_dialled) {
        await _caller.endpoint
            .close()
            .timeout(const Duration(seconds: 3), onTimeout: () {})
            .catchError((Object _) {});
      }
      await _rig.close().timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    if (found == null && uncaught.isNotEmpty) {
      found = _violation('I-4', 'uncaught async error: ${uncaught.first}');
    }
    return found;
  }

  Future<_Violation?> _body() async {
    _caller = await _rig.caller();
    _dialled = true;
    // A first call opens whatever the connection opens lazily, so the
    // baseline is a connection that has carried a call.
    await _caller
        .unary(Blob.request(id: nextCallId()))
        .timeout(const Duration(seconds: 5));
    final serverBase = await _rig.serverMetrics();
    final clientBase = await endpointGauges(_caller.endpoint);

    _clock.start();
    for (_step = 0; _step < ops.length; _step++) {
      await _apply(ops[_step]);
      await Future<void>.delayed(Duration.zero);
      final v = _check();
      if (v != null) return v;
    }
    return _drain(serverBase, clientBase);
  }

  Future<void> _apply(_Op op) async {
    if (op is _Start) return _start(op);
    if (op is _Wait) {
      await Future<void>.delayed(Duration(milliseconds: op.ms));
      return;
    }
    if (op is _CloseEndpoint) return _close();
    final c = _calls[op.call];
    if (c == null) return; // its start was shrunk away
    switch (op) {
      case _Send():
        if (c.op.streamsRequests && !c.requests.isClosed) {
          c.requests.add(Blob.request(id: c.id, count: c.op.count));
          c.sent++;
        }
      case _HalfClose():
        _halfClose(c);
      case _Pause():
        final sub = c.sub;
        if (sub != null && !c.paused && !c.cancelledSubscription) {
          c.paused = true;
          sub.pause();
        }
      case _Resume():
        _resume(c);
      case _Cancel():
        await _cancel(c, op.viaToken);
      case _Start() || _Wait() || _CloseEndpoint():
        break;
    }
  }

  void _start(_Start op) {
    final id = nextCallId();
    final c = _Live(op, id, _now);
    _calls[op.call] = c;
    var context = RpcContext.withCancellation(c.token);
    if (op.deadlineMs case final ms?) {
      context = context.withTimeout(Duration(milliseconds: ms));
    }
    final request = Blob.request(
      id: id,
      mode: op.mode,
      count: op.count,
      delayMs: op.delayMs,
    );
    try {
      switch (op.shape) {
        case CallShape.unary:
          _settle(c, _caller.unary(request, context: context));
        case CallShape.clientStream:
          c.requests.add(request);
          if (!op.open) _halfClose(c);
          _settle(c, _caller.clientStream(c.requests.stream, context: context));
        case CallShape.serverStream:
          _listen(c, _caller.serverStream(request, context: context));
        case CallShape.bidi:
          c.requests.add(request);
          if (!op.open) _halfClose(c);
          _listen(c, _caller.bidi(c.requests.stream, context: context));
      }
    } catch (e) {
      _end(c, e);
    }
  }

  void _settle(_Live c, Future<Blob> result) {
    result.then((_) {
      c.responses++;
      _end(c, null);
    }, onError: (Object e) => _end(c, e));
  }

  void _listen(_Live c, Stream<Blob> responses) {
    c.sub = responses.listen(
      (_) {
        if (c.ended) c.twice.add('a response after the call ended');
        c.responses++;
      },
      onError: (Object e) {
        c.errors++;
        if (c.errors > 1) c.twice.add('a second error: $e');
        if (c.dones > 0) c.twice.add('an error after done: $e');
        if (!c.ended) _end(c, e);
      },
      onDone: () {
        c.dones++;
        if (c.dones > 1) c.twice.add('a second done');
        if (!c.ended) _end(c, null);
      },
    );
  }

  void _end(_Live c, Object? error) {
    final bound = _bound(c);
    c.endedAt = _now;
    c.error = error;
    if (bound != null && c.endedAt! > bound) {
      c.late =
          'ended ${(c.endedAt! - bound + _slack).inMilliseconds} ms after its '
          'earliest trigger';
    }
    if (!c.requests.isClosed) c.requests.close().ignore();
  }

  void _halfClose(_Live c) {
    if (!c.op.streamsRequests || c.halfClosedAt != null) return;
    c.halfClosedAt = _now;
    if (!c.requests.isClosed) c.requests.close().ignore();
  }

  void _resume(_Live c) {
    if (!c.paused) return;
    c.paused = false;
    c.resumedAt = _now;
    if (!c.cancelledSubscription) c.sub?.resume();
  }

  Future<void> _cancel(_Live c, bool viaToken) async {
    if (c.cancelledAt != null) return;
    c.cancelledAt = _now;
    if (viaToken || !c.op.streamsResponses) {
      c.token.cancel('the model cancels');
      return;
    }
    c.cancelledSubscription = true;
    c.paused = false;
    // A cancelled subscription reports nothing more: the call ends here.
    if (!c.ended) _end(c, RpcCancelledException('subscription cancelled'));
    final sub = c.sub;
    if (sub == null) return;
    var returned = true;
    await sub.cancel().timeout(_slack, onTimeout: () => returned = false);
    if (!returned) c.twice.add('subscription.cancel() did not return in 1 s');
  }

  void _close() {
    if (_closing != null) return;
    _closedAt = _now;
    _closing = _caller.endpoint.close().whenComplete(() => _closeDone = true);
  }

  Duration? _natural(_Live c) {
    if (c.op.mode == Mode.hang) return null;
    final from = c.op.streamsRequests ? c.halfClosedAt : c.startedAt;
    return from == null ? null : from + Duration(milliseconds: c.op.delayMs);
  }

  Duration? _deadlineAt(_Live c) => c.op.deadlineMs == null
      ? null
      : c.startedAt + Duration(milliseconds: c.op.deadlineMs!);

  /// The latest moment [c] may end: its earliest trigger + [_slack], or from
  /// its resume when it was paused; null while nothing bounds it.
  Duration? _bound(_Live c) {
    if (c.paused) return null;
    final closed = _closedAt;
    final triggers = [
      ?_deadlineAt(c),
      ?c.cancelledAt,
      if (closed != null) closed > c.startedAt ? closed : c.startedAt,
      ?_natural(c),
    ];
    if (triggers.isEmpty) return null;
    var bound = triggers.reduce((a, b) => a < b ? a : b) + _slack;
    final resumed = c.resumedAt;
    if (resumed != null && resumed + _slack > bound) bound = resumed + _slack;
    return bound;
  }

  _Violation? _check() {
    if (uncaught.isNotEmpty) {
      return _violation('I-4', 'uncaught async error: ${uncaught.first}');
    }
    for (final c in _calls.values) {
      if (c.twice.isNotEmpty) {
        return _violation('ends once', '${c.twice.first}; ${c.describe()}');
      }
      if (c.late != null) {
        return _violation('I-1', '${c.late}; ${c.describe()}');
      }
      final bound = _bound(c);
      if (!c.ended && bound != null && _now > bound) {
        return _violation(
          'I-1',
          'not ended ${(_now - bound + _slack).inMilliseconds} ms after its '
              'earliest trigger; ${c.describe()}',
        );
      }
      for (final kind in const ['enter', 'disposed', 'timerCancelled']) {
        final n = _rig.probe.count(kind, id: c.id);
        if (n > 1) {
          return _violation(
            'ends once',
            'the handler reported "$kind" $n times; ${c.describe()}',
          );
        }
      }
    }
    return null;
  }

  Future<_Violation?> _drain(
    Map<String, int> serverBase,
    Map<String, int> clientBase,
  ) async {
    for (final c in _calls.values) {
      _resume(c);
      _halfClose(c);
    }
    final giveUp = _now + const Duration(seconds: 10);
    while (true) {
      final v = _check();
      if (v != null) return v;
      if (_calls.values.every((c) => c.ended)) break;
      if (_now > giveUp) {
        final c = _calls.values.firstWhere((c) => !c.ended);
        return _violation('I-1', 'nothing bounds this call; ${c.describe()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    if (_closing case final closing?) {
      await closing
          .timeout(const Duration(seconds: 3), onTimeout: () {})
          .catchError((Object _) {});
      if (!_closeDone) {
        return _violation(
          'I-5',
          'the caller endpoint did not close within 3 s of the drain',
        );
      }
    }

    // Closing a spawned isolate's transport kills the worker, so after a
    // close the server and its handlers are simply gone.
    final serverGone = _closing != null && _rig is IsolateRig;

    // Every handler that entered is disposed and releases its timer.
    final entered = [
      for (final c in _calls.values)
        if (!serverGone && _rig.probe.has('enter', c.id)) c,
    ];
    final settle = _now + const Duration(seconds: 2);
    while (true) {
      final pending = [
        for (final c in entered)
          for (final kind in const ['disposed', 'timerCancelled'])
            if (!_rig.probe.has(kind, c.id)) (kind, c),
      ];
      if (pending.isEmpty) break;
      if (_now > settle) {
        final (kind, c) = pending.first;
        return _violation(
          'I-5',
          'the handler never reported "$kind" within 2 s of the drain '
              '(${pending.length} reports missing); ${c.describe()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final v = _check();
    if (v != null) return v;

    // The gauges are back at baseline. A closed endpoint has dropped its
    // registrations, on both sides of the connection, which is not a leak.
    final ignore = {..._notAGauge, if (_closing != null) ..._registrations};
    // The server's flow-control residue on the channel transport (the
    // isolate one is built on it) is lead B-279 in .claude/loop/backlog and
    // still caught by the I-5 rows; here it would hide everything else.
    final skipFc = _rig is ChannelRig || _rig is IsolateRig;
    Map<String, String> drift = {};
    while (true) {
      drift = serverGone
          ? const {}
          : {
              for (final e in _drift(
                serverBase,
                await _rig.serverMetrics(),
                ignore,
              ).entries)
                if (!(skipFc && e.key.startsWith('fc.'))) e.key: e.value,
            };
      if (drift.isEmpty) {
        drift = {
          for (final e in _drift(
            clientBase,
            await endpointGauges(_caller.endpoint),
            ignore,
          ).entries)
            'client ${e.key}': e.value,
        };
      }
      if (drift.isEmpty) break;
      if (_now > settle) {
        return _violation(
          'I-5',
          'gauges not back at baseline 2 s after the drain: $drift',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    for (final c in _calls.values) {
      final wrong = _wrongEnding(c);
      if (wrong != null) return _violation('ending', '$wrong; ${c.describe()}');
    }
    return null;
  }

  /// Why [c] did not end the way its handler and deadline say, or null. Only
  /// for a call nothing else touched, whose two endings are [_margin] apart.
  String? _wrongEnding(_Live c) {
    if (c.cancelledAt != null || _closedAt != null) return null;
    final natural = _natural(c);
    final deadline = _deadlineAt(c);
    final status = c.error == null
        ? RpcStatus.ok
        : Outcome.error(c.error!).status;
    if (natural != null && (deadline == null || natural + _margin < deadline)) {
      if (c.op.mode == Mode.fail) {
        return status == RpcStatus.aborted
            ? null
            : 'expected the handler\'s ABORTED, got status $status';
      }
      final expected = switch (c.op.shape) {
        CallShape.unary || CallShape.clientStream => 1,
        CallShape.serverStream => c.op.count,
        CallShape.bidi => c.op.count * c.sent,
      };
      if (status != RpcStatus.ok) return 'expected ok, got status $status';
      if (c.responses != expected) {
        return 'expected $expected responses, got ${c.responses}';
      }
      return null;
    }
    if (deadline != null && (natural == null || deadline + _margin < natural)) {
      return status == RpcStatus.deadlineExceeded
          ? null
          : 'expected DEADLINE_EXCEEDED, got status $status';
    }
    return null;
  }
}

/// The keys of [now] that differ from [baseline] (a missing key is 0), but
/// for those in [ignore].
Map<String, String> _drift(
  Map<String, int> baseline,
  Map<String, int> now,
  Set<String> ignore,
) => {
  for (final k in {...baseline.keys, ...now.keys})
    if (!ignore.contains(k) && (baseline[k] ?? 0) != (now[k] ?? 0))
      k: '${baseline[k] ?? 0} -> ${now[k] ?? 0}',
};

// -------------------------------------------------------------- shrinking --

/// Removes operations from [ops] while [member] still fails the same property
/// as [first]: chunks of half the sequence, then of a quarter, down to single
/// operations. Returns the smallest failing sequence, its failure and the
/// number of runs spent.
Future<(List<_Op>, _Violation, int)> _shrink(
  Member member,
  List<_Op> ops,
  _Violation first,
) async {
  var current = ops;
  var failure = first;
  var runs = 0;
  var chunk = (current.length / 2).ceil();
  while (chunk >= 1 && runs < _shrinkRuns) {
    var removed = false;
    var i = 0;
    while (i < current.length && runs < _shrinkRuns) {
      final candidate = [
        ...current.sublist(0, i),
        ...current.sublist(min(i + chunk, current.length)),
      ];
      runs++;
      final v = await _run(member, candidate);
      if (v != null && v.kind == failure.kind) {
        current = candidate;
        failure = v;
        removed = true;
      } else {
        i += chunk;
      }
    }
    if (!removed) chunk ~/= 2;
  }
  return (current, failure, runs);
}
