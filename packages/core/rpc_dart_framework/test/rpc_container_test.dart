// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class _Service {}

void main() {
  test('registerFactory returns a fresh instance per get()', () {
    final c = RpcContainer();
    c.registerFactory<_Service>((_) => _Service());

    expect(identical(c.get<_Service>(), c.get<_Service>()), isFalse);
  });

  test(
    'registerLazySingleton returns the same instance across get() calls',
    () {
      final c = RpcContainer();
      var created = 0;
      c.registerLazySingleton<_Service>((_) {
        created++;
        return _Service();
      });

      final a = c.get<_Service>();
      final b = c.get<_Service>();

      expect(
        identical(a, b),
        isTrue,
        reason: 'lazy-singleton must memoize the first created instance',
      );
      expect(created, 1, reason: 'factory must run at most once');
    },
  );

  test('registerLazySingleton defers creation until first get()', () {
    final c = RpcContainer();
    var created = 0;
    c.registerLazySingleton<_Service>((_) {
      created++;
      return _Service();
    });

    expect(created, 0, reason: 'creation must be lazy');
    c.get<_Service>();
    expect(created, 1);
  });
}
