// Audit finding 7: RpcContainer.tryGet swallows a StateError thrown INSIDE a
// factory, conflating "not registered" with "factory failed".
// Source: lib/src/rpc_container.dart:58-64.
//   tryGet calls get<T>() and catches `on StateError -> return null`. get()
//   throws StateError when unregistered, but a factory body that itself throws
//   StateError is indistinguishable -> silently returns null, hiding the bug.

import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class _Service {}

void main() {
  test(
    'tryGet does not silently swallow a StateError from the factory body',
    () {
      final c = RpcContainer();
      c.registerFactory<_Service>(
        (_) => throw StateError('dependency misconfigured'),
      );

      // CORRECT behavior: a registered-but-failing factory must surface its
      // error, NOT be reported as "not registered" (null).
      expect(
        () => c.tryGet<_Service>(),
        throwsA(isA<StateError>()),
        reason: 'factory failure must not be conflated with "not registered"',
      );
    },
  );
}
