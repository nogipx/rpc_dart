// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// An [IRpcInterceptor] that injects errors or latency into specific RPC methods.
///
/// Useful for testing how clients and modules handle failures, retries, and
/// timeouts without changing production handler code.
///
/// ```dart
/// final faults = RpcFaultInjector()
///   ..failMethod('UserService', 'getUser', RpcException('not found'))
///   ..delayMethod('OrderService', 'createOrder', Duration(milliseconds: 200));
///
/// final app = await RpcTestApp.start(
///   modules: [UserModule(), OrderModule()],
///   interceptors: [faults],
/// );
/// ```
///
/// Fault lookup key is `'ServiceName.methodName'`. Delays are applied before
/// error injection. Per-method one-shot errors ([failMethodOnce]) are queued
/// and consumed in registration order; permanent errors ([failMethod]) fire
/// after the one-shot queue is exhausted.
class RpcFaultInjector extends IRpcInterceptor {
  final Map<String, Object> _permanent = {};
  final Map<String, List<Object>> _once = {};
  final Map<String, Duration> _delays = {};

  /// Always throw [error] when [service].[method] is called.
  ///
  /// Replaces any previous permanent error for the same key.
  void failMethod(String service, String method, Object error) =>
      _permanent['$service.$method'] = error;

  /// Throw [error] on the next call to [service].[method], then remove it.
  ///
  /// Multiple calls queue errors in registration order. Once the queue is
  /// drained, any permanent error registered via [failMethod] takes over.
  void failMethodOnce(String service, String method, Object error) =>
      _once.putIfAbsent('$service.$method', () => []).add(error);

  /// Add [delay] before processing each call to [service].[method].
  ///
  /// Delay is applied before error injection, so it affects both success and
  /// fault paths.
  void delayMethod(String service, String method, Duration delay) =>
      _delays['$service.$method'] = delay;

  /// Remove all faults (permanent error, one-shot queue, and delay) for
  /// [service].[method].
  void removeMethod(String service, String method) {
    final key = '$service.$method';
    _permanent.remove(key);
    _once.remove(key);
    _delays.remove(key);
  }

  /// Remove all registered faults and delays.
  void clear() {
    _permanent.clear();
    _once.clear();
    _delays.clear();
  }

  Future<void> _applyFault(String service, String method) async {
    final key = '$service.$method';

    final delay = _delays[key];
    if (delay != null) await Future<void>.delayed(delay);

    final onceQueue = _once[key];
    if (onceQueue != null && onceQueue.isNotEmpty) {
      // ignore: only_throw_errors — callers may register arbitrary objects
      throw onceQueue.removeAt(0);
    }

    final permanent = _permanent[key];
    if (permanent != null) {
      // ignore: only_throw_errors
      throw permanent;
    }
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    await _applyFault(call.serviceName, call.methodName);
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    await _applyFault(call.serviceName, call.methodName);
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    await _applyFault(call.serviceName, call.methodName);
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    await _applyFault(call.serviceName, call.methodName);
    return next(call.context, requests);
  }
}
