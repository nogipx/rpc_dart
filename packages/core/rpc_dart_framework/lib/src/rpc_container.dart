// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Lightweight type-keyed service container.
///
/// Supports singletons (registered instances) and factories (created on demand).
/// Factories receive the container so they can resolve their own dependencies.
///
/// Registration order does not matter — resolution is lazy for factories and
/// immediate for singletons.
///
/// Example:
/// ```dart
/// final c = RpcContainer();
/// c.registerSingleton<Database>(PostgresDatabase(url));
/// c.registerFactory<UserRepo>((c) => UserRepo(c.get<Database>()));
///
/// final repo = c.get<UserRepo>(); // creates UserRepo with injected Database
/// ```
class RpcContainer {
  final Map<Type, Object> _singletons = {};
  final Map<Type, Object Function(RpcContainer)> _factories = {};

  /// Registers [instance] as the singleton for type [T].
  ///
  /// Always returns the same instance. Overwrites any existing registration.
  void registerSingleton<T extends Object>(T instance) {
    _singletons[T] = instance;
  }

  /// Registers a [factory] that creates a new [T] each time [get] is called.
  ///
  /// The factory receives this container so it can resolve dependencies.
  /// Overwrites any existing factory registration for [T].
  void registerFactory<T extends Object>(T Function(RpcContainer c) factory) {
    _factories[T] = (c) => factory(c);
  }

  /// Resolves [T] from the container.
  ///
  /// Singletons take priority over factories.
  /// Throws [StateError] if [T] is not registered.
  T get<T extends Object>() {
    final singleton = _singletons[T];
    if (singleton != null) return singleton as T;

    final factory = _factories[T];
    if (factory != null) return factory(this) as T;

    throw StateError(
      'RpcContainer: no registration found for type $T. '
      'Call registerSingleton<$T>() or registerFactory<$T>() first.',
    );
  }

  /// Resolves [T] from the container, returning null if not registered.
  T? tryGet<T extends Object>() {
    try {
      return get<T>();
    } on StateError {
      return null;
    }
  }

  /// Returns true when [T] has a singleton or factory registration.
  bool has<T extends Object>() =>
      _singletons.containsKey(T) || _factories.containsKey(T);

  /// Removes all registrations. Useful in tests.
  void clear() {
    _singletons.clear();
    _factories.clear();
  }
}
