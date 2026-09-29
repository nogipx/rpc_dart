// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `LogScope.isInternal` resolves through `LogController._resolveLevel`, which used
// to walk every configured scope override with a `startsWith` per entry. The
// library's logging idiom guards every interpolating call with that check, so the
// scan ran at hundreds of sites whether or not logging was on, at a cost
// proportional to how many overrides the application had configured.
//
// It is now a map read. The risk in any cache is STALENESS, so that is what these
// tests are about: every way the configuration can change must be visible to the
// next resolution.
//
// `minLevel` is the awkward one — a public mutable field with no hook to invalidate
// anything, so the cache remembers which level it was built under.
//
// The measurements are in `.claude/loop/rounds/512`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _scope = 'rpc_dart.transport.websocket.caller';

void main() {
  group('GUARD: resolution is unchanged', () {
    test('a scope override applies', () {
      final c = LogController(minLevel: RpcLogLevel.warning);
      final log = LogScope(c, _scope);
      expect(log.isInternal, isFalse);

      c.setScopeLevel('rpc_dart.transport', RpcLogLevel.internal);
      expect(log.isInternal, isTrue);
    });

    test('the LONGEST matching prefix wins, not the first', () {
      final c = LogController(minLevel: RpcLogLevel.warning)
        ..setScopeLevel('rpc_dart', RpcLogLevel.internal)
        ..setScopeLevel('rpc_dart.transport.websocket', RpcLogLevel.error);

      expect(
        LogScope(c, _scope).isInternal,
        isFalse,
        reason: 'the longer prefix sets error, which internal does not reach',
      );
      expect(LogScope(c, 'rpc_dart.endpoint').isInternal, isTrue);
    });

    test('a tag override beats a scope override', () {
      final c = LogController(minLevel: RpcLogLevel.warning)
        ..setScopeLevel('rpc_dart', RpcLogLevel.error)
        ..setTagLevel('noisy', RpcLogLevel.internal);

      expect(LogScope(c, _scope, tag: 'noisy').isInternal, isTrue);
      expect(LogScope(c, _scope).isInternal, isFalse);
    });

    test('an unmatched scope falls back to minLevel', () {
      final c = LogController(minLevel: RpcLogLevel.internal)
        ..setScopeLevel('something.else', RpcLogLevel.error);
      expect(LogScope(c, _scope).isInternal, isTrue);
    });
  });

  // Every test in this file is a GUARD. The defect is a cost, so none of them can
  // witness it — with the cache bypassed all ten still pass, because the scanning
  // version was correct. The witness is the bench. What these pin is the risk the
  // FIX introduces, which the defect never had: a stale answer.
  group('GUARD: the cache cannot go stale', () {
    test('adding an override after a resolution takes effect', () {
      final c = LogController(minLevel: RpcLogLevel.warning);
      final log = LogScope(c, _scope);
      expect(log.isInternal, isFalse); // populates the cache

      c.setScopeLevel('rpc_dart', RpcLogLevel.internal);
      expect(
        log.isInternal,
        isTrue,
        reason: 'setScopeLevel must invalidate what was already resolved',
      );
    });

    test('CHANGING an override takes effect', () {
      final c = LogController(minLevel: RpcLogLevel.warning)
        ..setScopeLevel('rpc_dart', RpcLogLevel.internal);
      final log = LogScope(c, _scope);
      expect(log.isInternal, isTrue);

      c.setScopeLevel('rpc_dart', RpcLogLevel.error);
      expect(log.isInternal, isFalse);
    });

    test('clearing an override takes effect', () {
      final c = LogController(minLevel: RpcLogLevel.warning)
        ..setScopeLevel('rpc_dart', RpcLogLevel.internal);
      final log = LogScope(c, _scope);
      expect(log.isInternal, isTrue);

      c.clearScopeLevel('rpc_dart');
      expect(log.isInternal, isFalse);
    });

    test('assigning minLevel takes effect', () {
      // The awkward case: a public mutable field, so nothing calls a setter that
      // could clear the cache. The cache remembers which minLevel it was built
      // under and discards itself when that changes.
      final c = LogController(minLevel: RpcLogLevel.warning);
      final log = LogScope(c, _scope);
      expect(log.isInternal, isFalse);

      c.minLevel = RpcLogLevel.internal;
      expect(
        log.isInternal,
        isTrue,
        reason:
            'minLevel is the fallback the cached value was computed from; '
            'reassigning it must not leave the old answer in place',
      );

      c.minLevel = RpcLogLevel.error;
      expect(log.isInternal, isFalse);
    });

    test('a tag override added later still beats the cached scope', () {
      final c = LogController(minLevel: RpcLogLevel.warning);
      final log = LogScope(c, _scope, tag: 'noisy');
      expect(log.isInternal, isFalse);

      c.setTagLevel('noisy', RpcLogLevel.internal);
      expect(
        log.isInternal,
        isTrue,
        reason: 'the tag is read before the cache, so it needs no invalidation',
      );
    });
  });

  test('GUARD: many distinct scopes stay correct past the cache bound', () {
    // `child()` concatenates names, so a caller creating many short-lived scopes
    // grows the map. It is cleared wholesale at the bound; what must not happen is
    // a wrong answer on either side of that.
    final c = LogController(minLevel: RpcLogLevel.warning)
      ..setScopeLevel('rpc_dart.keep', RpcLogLevel.internal);

    for (var i = 0; i < 1200; i++) {
      expect(LogScope(c, 'rpc_dart.churn.$i').isInternal, isFalse);
      expect(LogScope(c, 'rpc_dart.keep.$i').isInternal, isTrue);
    }
  });
}
