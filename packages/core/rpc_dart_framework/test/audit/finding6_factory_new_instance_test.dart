// Audit finding 6: RpcContainer.registerFactory creates a NEW instance per
// get(), and docs recommend it for services -> a new service instance per
// resolution (per connection), silently breaking singleton expectations and
// offering no lazy-singleton option.
// Source: lib/src/rpc_container.dart:36-49.
//   registerFactory stores `(c) => factory(c)`; get() at 44-54 calls it every
//   time, so two get<T>() calls yield two distinct objects.

import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class _Service {}

void main() {
  test(
    'registerFactory returns a fresh instance per get() (no lazy-singleton)',
    () {
      final c = RpcContainer();
      c.registerFactory<_Service>((_) => _Service());

      final a = c.get<_Service>();
      final b = c.get<_Service>();

      // registerFactory must yield a fresh instance per get() (by contract).
      expect(
        identical(a, b),
        isFalse,
        reason: 'factory yields a new instance per get()',
      );

      // The shared-instance use case is now served by registerLazySingleton.
      final d = RpcContainer();
      d.registerLazySingleton<_Service>((_) => _Service());
      expect(
        identical(d.get<_Service>(), d.get<_Service>()),
        isTrue,
        reason: 'lazy singleton memoizes a single shared instance',
      );
    },
  );
}
