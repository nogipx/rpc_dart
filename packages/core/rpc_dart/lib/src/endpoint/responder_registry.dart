// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Associates a method key with its registration.
final class RpcResponderMethodBinding {
  /// Service that owns this method.
  final String serviceName;

  /// Method name within the service.
  final String methodName;

  /// The method as its contract registered it.
  final RpcMethodRegistration<Object, Object> registration;

  /// Creates a method binding.
  RpcResponderMethodBinding({
    required this.serviceName,
    required this.methodName,
    required this.registration,
  });

  /// Communication pattern of the method.
  RpcMethodType get type => registration.type;

  /// Fully-qualified key `serviceName.methodName`.
  String get methodKey => '$serviceName.$methodName';

  /// True when this binding uses zero-copy (no serialization).
  bool get isZeroCopy => registration.isZeroCopy;
}

/// Stores and manages registered contracts and their method bindings.
final class RpcResponderMethodRegistry {
  LogScope _log = LogScope.noop;
  final Map<String, RpcResponderContract> _contracts = {};
  final Map<String, RpcResponderMethodBinding> _methods = {};

  /// All registered contracts, keyed by service name.
  Map<String, RpcResponderContract> get contracts =>
      Map.unmodifiable(_contracts);

  /// All method bindings keyed by `serviceName.methodName`.
  Map<String, RpcResponderMethodBinding> get methods =>
      Map.unmodifiable(_methods);

  /// Every registration, keyed by `serviceName.methodName`.
  Map<String, RpcMethodRegistration<Object, Object>>
  exportMethodRegistrations() => Map.unmodifiable({
    for (final entry in _methods.entries) entry.key: entry.value.registration,
  });

  /// Registers [contract] and indexes all its methods.
  ///
  /// **All or nothing.** Everything that can throw — `setup()`, and the
  /// duplicate-key check for every method — runs before any field is touched, and
  /// the bindings are built into a local map that is committed in one step at the
  /// end. Inserting the contract first left a failed registration half-applied:
  /// the service was present, some of its methods were live and served requests,
  /// and the obvious recovery (catch, fix, register again) was refused with
  /// "already registered".
  void registerContract(RpcResponderContract contract, LogScope? logger) {
    if (logger != null) _log = logger;
    final serviceName = contract.serviceName;

    if (_contracts.containsKey(serviceName)) {
      // Registration-time mistakes, all four of them: this side wired itself up
      // wrongly and no peer is involved, so INTERNAL is the honest status.
      throw RpcStatusException(
        RpcStatus.internal,
        'Contract for service $serviceName is already registered',
      );
    }

    if (_log.isInternal) {
      _log.internal('Registering service contract: $serviceName');
    }

    // Only if nothing has been declared yet. `setup()` is public and calling it
    // before registering reads as the natural thing to do -- two transport
    // packages' tests do exactly that -- and this used to run it a SECOND time,
    // re-registering every method. That was harmless only because a repeated
    // name silently replaced the earlier entry; now that a duplicate is
    // refused, re-running it would throw on correct code.
    //
    // This also makes registering one contract instance on two endpoints work,
    // which had the same double-setup problem.
    if (contract.registrations.isEmpty) {
      contract.setup();
    }

    // Built locally, committed at the end. `pending` is also checked against
    // itself: two of this contract's own methods sharing a key must be refused
    // here rather than silently collapsing into one binding.
    final pending = <String, RpcResponderMethodBinding>{};

    // The wire's grammar, at registration. The binding key `'$service.$method'`
    // is unambiguous only because a method name has no dot (see
    // [kMethodTokenPattern]); registered unchecked, method `a.b` on `S` took
    // the key of method `b` on service `S.a`, and a call for `/S.a/b` was
    // served by the wrong service's handler. A name the grammar refuses also
    // registers a method no caller can reach.
    if (!kServiceTokenPattern.hasMatch(serviceName)) {
      throw RpcStatusException(
        RpcStatus.internal,
        'Invalid service name "$serviceName": allowed are letters, digits, '
        '"_", "-" and "."',
      );
    }

    void reserve(String methodName, RpcResponderMethodBinding binding) {
      if (!kMethodTokenPattern.hasMatch(methodName)) {
        throw RpcStatusException(
          RpcStatus.internal,
          'Invalid method name "$methodName" in $serviceName: allowed are '
          'letters, digits, "_" and "-"',
        );
      }
      final methodKey = '$serviceName.$methodName';
      if (_methods.containsKey(methodKey) || pending.containsKey(methodKey)) {
        throw RpcStatusException(
          RpcStatus.internal,
          'Method $methodKey is already registered',
        );
      }
      pending[methodKey] = binding;
    }

    for (final entry in contract.registrations.entries) {
      reserve(
        entry.key,
        RpcResponderMethodBinding(
          serviceName: serviceName,
          methodName: entry.key,
          registration: entry.value,
        ),
      );
    }

    // Commit. Nothing above this line has modified any field, so a throw leaves
    // the registry exactly as it was.
    _contracts[serviceName] = contract;
    _methods.addAll(pending);

    if (_log.isInternal) {
      for (final entry in pending.entries) {
        final binding = entry.value;
        _log.internal(
          'Registering method: ${entry.key} (${binding.type.name})'
          '${binding.isZeroCopy ? ' [ZERO-COPY]' : ''}',
        );
      }
      _log.internal(
        'Contract $serviceName registered with ${pending.length} methods',
      );
    }
  }

  /// Removes the contract for [serviceName] and its method bindings.
  void unregisterContract(String serviceName, LogScope? logger) {
    if (logger != null) _log = logger;
    final contract = _contracts.remove(serviceName);

    if (contract == null) {
      throw RpcStatusException(
        RpcStatus.internal,
        'Contract for service $serviceName is not registered',
      );
    }

    if (_log.isInternal) {
      _log.internal('Unregistering service contract: $serviceName');
    }

    // Match on the binding's own serviceName, not on a '$serviceName.' key
    // prefix. Service names may legitimately contain dots -- gRPC names are
    // conventionally package-qualified (`my.pkg.v1.UserService`), and the
    // metadata validator allows them -- so the prefix form also matched every
    // method of every service nested under this one. Unregistering `Foo` tore
    // the methods out of `Foo.Bar` while leaving its contract registered: its
    // calls started failing UNIMPLEMENTED and it could not be re-registered.
    final methodKeys = _methods.entries
        .where((entry) => entry.value.serviceName == serviceName)
        .map((entry) => entry.key)
        .toList();

    for (final methodKey in methodKeys) {
      final binding = _methods.remove(methodKey);
      if (binding != null && _log.isInternal) {
        _log.internal(
          'Unregistering method: $methodKey (${binding.type.name})',
        );
      }
    }

    try {
      contract.dispose();
      if (_log.isInternal) {
        _log.internal('Contract $serviceName resources released');
      }
    } catch (error, stackTrace) {
      _log.error(
        'Error releasing resources of contract $serviceName: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Disposes all registered contracts and clears the registry.
  void disposeAll(LogScope? logger) {
    if (logger != null) _log = logger;
    for (final entry in _contracts.entries) {
      final serviceName = entry.key;
      final contract = entry.value;

      try {
        contract.dispose();
        if (_log.isInternal) {
          _log.internal(
            'Contract $serviceName resources released on endpoint close',
          );
        }
      } catch (error, stackTrace) {
        _log.error(
          'Error releasing resources of contract $serviceName: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    _contracts.clear();
    _methods.clear();
  }

  /// Returns the binding for [methodKey], or null if not registered.
  RpcResponderMethodBinding? lookup(String methodKey) => _methods[methodKey];

  /// Returns true if [methodKey] is registered.
  bool containsMethod(String methodKey) => _methods.containsKey(methodKey);
}
