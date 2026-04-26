// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_app_config.dart';
import 'rpc_module.dart';

// ============================================================================
// Module ordering
// ============================================================================

/// Topological sort of [modules] by [RpcModule.dependencies] (Kahn's algorithm).
///
/// Throws [StateError] on circular dependencies or missing dependency types.
List<RpcModule> sortModulesByDependencies(List<RpcModule> modules) {
  final byType = <Type, RpcModule>{};
  for (final m in modules) {
    byType[m.runtimeType] = m;
  }

  final inDegree = <RpcModule, int>{for (final m in modules) m: 0};
  final dependents = <RpcModule, List<RpcModule>>{};

  for (final m in modules) {
    for (final depType in m.dependencies) {
      final dep = byType[depType];
      if (dep == null) {
        throw StateError(
          'Module "${m.name}" declares dependency on $depType '
          'but no module of that type is registered.',
        );
      }
      inDegree[m] = inDegree[m]! + 1;
      dependents.putIfAbsent(dep, () => []).add(m);
    }
  }

  final queue = modules.where((m) => inDegree[m] == 0).toList();
  final sorted = <RpcModule>[];

  while (queue.isNotEmpty) {
    final m = queue.removeAt(0);
    sorted.add(m);
    for (final dependent in dependents[m] ?? const []) {
      inDegree[dependent] = inDegree[dependent]! - 1;
      if (inDegree[dependent] == 0) queue.add(dependent);
    }
  }

  if (sorted.length != modules.length) {
    final unresolved = modules
        .where((m) => !sorted.contains(m))
        .map((m) => m.name)
        .join(', ');
    throw StateError(
      'Circular dependency detected among modules: $unresolved',
    );
  }

  return sorted;
}

// ============================================================================
// Auto-wired interceptors
// ============================================================================

/// Intercepts all call types and routes exceptions to [RpcAppConfig.onError].
class ErrorReportingInterceptor extends IRpcInterceptor {
  final RpcErrorHandler _handler;
  const ErrorReportingInterceptor(this._handler);

  void _report(Object e, StackTrace st, RpcMiddlewareContext call) {
    _handler(e, st, call.serviceName, call.methodName);
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    try {
      return await next(call.context, request);
    } catch (e, st) {
      _report(e, st, call);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    try {
      final stream = await Future<Stream<TResponse>>.value(
        next(call.context, request),
      );
      return _wrapStream(stream, call);
    } catch (e, st) {
      _report(e, st, call);
      rethrow;
    }
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    try {
      return await next(call.context, requests);
    } catch (e, st) {
      _report(e, st, call);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    try {
      final stream = await Future<Stream<TResponse>>.value(
        next(call.context, requests),
      );
      return _wrapStream(stream, call);
    } catch (e, st) {
      _report(e, st, call);
      rethrow;
    }
  }

  Stream<T> _wrapStream<T>(Stream<T> source, RpcMiddlewareContext call) async* {
    try {
      await for (final item in source) {
        yield item;
      }
    } catch (e, st) {
      _report(e, st, call);
      rethrow;
    }
  }
}

/// Intercepts all call types and emits a [RpcCallEvent] after each completes.
class CallMetricsInterceptor extends IRpcInterceptor {
  final RpcCallObserver _observer;
  const CallMetricsInterceptor(this._observer);

  void _emit({
    required RpcMiddlewareContext call,
    required String callType,
    required Stopwatch sw,
    required bool success,
    Object? error,
  }) {
    _observer(RpcCallEvent(
      serviceName: call.serviceName,
      methodName: call.methodName,
      callType: callType,
      duration: sw.elapsed,
      success: success,
      context: call.context,
      error: error,
    ));
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final res = await next(call.context, request);
      _emit(call: call, callType: 'unary', sw: sw, success: true);
      return res;
    } catch (e) {
      _emit(call: call, callType: 'unary', sw: sw, success: false, error: e);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final stream = await Future<Stream<TResponse>>.value(
        next(call.context, request),
      );
      return _timedStream(stream, call, 'serverStream', sw);
    } catch (e) {
      _emit(call: call, callType: 'serverStream', sw: sw, success: false, error: e);
      rethrow;
    }
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final res = await next(call.context, requests);
      _emit(call: call, callType: 'clientStream', sw: sw, success: true);
      return res;
    } catch (e) {
      _emit(call: call, callType: 'clientStream', sw: sw, success: false, error: e);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final stream = await Future<Stream<TResponse>>.value(
        next(call.context, requests),
      );
      return _timedStream(stream, call, 'bidiStream', sw);
    } catch (e) {
      _emit(call: call, callType: 'bidiStream', sw: sw, success: false, error: e);
      rethrow;
    }
  }

  Stream<T> _timedStream<T>(
    Stream<T> source,
    RpcMiddlewareContext call,
    String callType,
    Stopwatch sw,
  ) async* {
    try {
      await for (final item in source) {
        yield item;
      }
      _emit(call: call, callType: callType, sw: sw, success: true);
    } catch (e) {
      _emit(call: call, callType: callType, sw: sw, success: false, error: e);
      rethrow;
    }
  }
}
