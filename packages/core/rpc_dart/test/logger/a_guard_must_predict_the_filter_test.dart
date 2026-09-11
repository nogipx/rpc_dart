// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `isInternal` exists so a call site can skip building a message the filter
// would drop. That only holds if it asks the filter's OWN question.
//
// It did not. The guard asked `accepts(level, name)` and `_log` asks
// `accepts(level, name, tag)`, while `_resolveLevel` consults the tag override
// ahead of both the scope overrides and `minLevel`. Configure a tag level and
// the two disagree — and in the direction that MUTES: the logger was set up to
// accept the record, the guard stopped it ever being offered, and the call
// still succeeded so nothing else noticed.
//
// The contract is one line: for every configuration, the guard and the delivery
// agree. Round 337 put this predicate in front of 222 call sites, so the cost
// of it being wrong is every one of them.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Emits one `internal()` on a scope built from [tag], and reports what the
/// guard said and whether the record actually reached the controller.
Future<({bool guard, bool delivered})> observe(
  void Function(LogController c) configure, {
  String? tag,
}) async {
  final c = LogController(minLevel: RpcLogLevel.error);
  configure(c);

  final arrived = <String>[];
  final sub = c.stream.listen((r) {
    if (r is LogEvent) arrived.add(r.message);
  });

  final scope = c.scope('rpc.probe', tag: tag);
  final guard = scope.isInternal;
  scope.internal('SENTINEL');
  await Future<void>.delayed(Duration.zero);

  await sub.cancel();
  c.dispose();
  return (guard: guard, delivered: arrived.contains('SENTINEL'));
}

void main() {
  test('the guard agrees with the filter under a tag override', () async {
    // The muting direction, and the one the fix is for. Without the tag in the
    // guard: guard false, delivered true.
    final r = await observe(
      (c) => c.setTagLevel('verbose', RpcLogLevel.internal),
      tag: 'verbose',
    );
    expect(
      r.delivered,
      isTrue,
      reason: 'the controller was configured to accept this record',
    );
    expect(
      r.guard,
      isTrue,
      reason:
          'the guard disagreed with the filter and so MUTED a record the '
          'logger accepts — every guarded call site loses its diagnostics',
    );
  });

  test('a tag override that RAISES the level also agrees', () async {
    // The other direction. Harmless on its own -- a string built and dropped --
    // but it is the same bug, and asserting only the loud half would leave the
    // guard free to ignore the tag whenever it raises the bar.
    final r = await observe((c) {
      c.setScopeLevel('rpc.', RpcLogLevel.internal);
      c.setTagLevel('quiet', RpcLogLevel.error);
    }, tag: 'quiet');
    expect(r.delivered, isFalse);
    expect(r.guard, isFalse);
  });

  test('the configurations with no tag still agree', () async {
    // GUARD against a fix that reads the tag and breaks everything else: these
    // two rows were correct before and must stay correct.
    final off = await observe((_) {});
    expect(off.guard, isFalse);
    expect(off.delivered, isFalse);

    final on = await observe(
      (c) => c.setScopeLevel('rpc.', RpcLogLevel.internal),
    );
    expect(on.guard, isTrue);
    expect(on.delivered, isTrue);
  });

  test('a tag survives child() and so must the agreement', () async {
    // Every guarded class builds its own scope with `logger?.child(...)`, and
    // `child` carries the tag (`tag: tag ?? this.tag`). So one tagged scope
    // handed to a transport reaches every site below it, at any depth.
    final c = LogController(minLevel: RpcLogLevel.error)
      ..setTagLevel('verbose', RpcLogLevel.internal);
    addTearDown(c.dispose);

    final arrived = <String>[];
    final sub = c.stream.listen((r) {
      if (r is LogEvent) arrived.add(r.message);
    });
    addTearDown(sub.cancel);

    final root = c.scope('rpc', tag: 'verbose');
    final grandchild = root.child('ServerResponder').child('StreamProcessor');

    expect(grandchild.tag, 'verbose', reason: 'child() must carry the tag');
    expect(grandchild.isInternal, isTrue);

    grandchild.internal('DEEP');
    await Future<void>.delayed(Duration.zero);
    expect(arrived, contains('DEEP'));
  });
}
