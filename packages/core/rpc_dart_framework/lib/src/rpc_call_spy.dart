// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// A single recorded RPC call entry produced by [RpcCallSpy].
class RpcSpyEntry {
  /// Name of the RPC service.
  final String serviceName;

  /// Name of the RPC method.
  final String methodName;

  /// One of `'unary'`, `'serverStream'`, `'clientStream'`, `'bidiStream'`.
  final String callType;

  /// True when the call completed without throwing.
  final bool success;

  /// The exception that was thrown, or null on success.
  final Object? error;

  /// Wall-clock duration of the call (for streams: until the stream ended).
  final Duration duration;

  /// When this call was recorded.
  final DateTime calledAt;

  /// The [RpcContext] that was active during the call.
  final RpcContext context;

  const RpcSpyEntry({
    required this.serviceName,
    required this.methodName,
    required this.callType,
    required this.success,
    required this.duration,
    required this.calledAt,
    required this.context,
    this.error,
  });

  @override
  String toString() {
    final status = success ? 'OK' : 'ERROR(${error.runtimeType})';
    return 'RpcSpyEntry($serviceName.$methodName [$callType] '
        '${duration.inMilliseconds}ms $status)';
  }
}

/// An [IRpcInterceptor] that records every RPC call for later inspection.
///
/// Attach to [RpcTestApp] or [RpcApp] to capture calls during tests, then
/// assert on [entries], [callsTo], [callCount], etc.
///
/// ```dart
/// final spy = RpcCallSpy();
/// final app = await RpcTestApp.start(
///   modules: [EchoModule()],
///   interceptors: [spy],
/// );
///
/// final client = EchoCallerContract(app.caller);
/// await client.ping(PingRequest('hello'));
/// await client.ping(PingRequest('world'));
///
/// expect(spy.callCount, 2);
/// expect(spy.callsTo('EchoService', 'ping'), hasLength(2));
/// expect(spy.entries.first.success, isTrue);
/// expect(spy.wasCalled('EchoService', 'ping'), isTrue);
/// ```
class RpcCallSpy extends IRpcInterceptor {
  final List<RpcSpyEntry> _entries = [];

  /// All recorded entries in call order.
  List<RpcSpyEntry> get entries => List.unmodifiable(_entries);

  /// Total number of recorded calls.
  int get callCount => _entries.length;

  /// Number of calls that completed successfully.
  int get successCount => _entries.where((e) => e.success).length;

  /// Number of calls that threw an error.
  int get errorCount => _entries.where((e) => !e.success).length;

  /// All entries for the given [service] and [method].
  List<RpcSpyEntry> callsTo(String service, String method) => _entries
      .where((e) => e.serviceName == service && e.methodName == method)
      .toList();

  /// Whether [service].[method] was called at least once.
  bool wasCalled(String service, String method) =>
      _entries.any((e) => e.serviceName == service && e.methodName == method);

  /// Removes all recorded entries.
  void reset() => _entries.clear();

  void _record({
    required RpcMiddlewareContext call,
    required String callType,
    required Stopwatch sw,
    required bool success,
    Object? error,
  }) {
    _entries.add(
      RpcSpyEntry(
        serviceName: call.serviceName,
        methodName: call.methodName,
        callType: callType,
        success: success,
        error: error,
        duration: sw.elapsed,
        calledAt: DateTime.now(),
        context: call.context,
      ),
    );
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
      _record(call: call, callType: 'unary', sw: sw, success: true);
      return res;
    } catch (e) {
      _record(call: call, callType: 'unary', sw: sw, success: false, error: e);
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
      return _trackStream(stream, call, 'serverStream', sw);
    } catch (e) {
      _record(
        call: call,
        callType: 'serverStream',
        sw: sw,
        success: false,
        error: e,
      );
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
      _record(call: call, callType: 'clientStream', sw: sw, success: true);
      return res;
    } catch (e) {
      _record(
        call: call,
        callType: 'clientStream',
        sw: sw,
        success: false,
        error: e,
      );
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
      return _trackStream(stream, call, 'bidiStream', sw);
    } catch (e) {
      _record(
        call: call,
        callType: 'bidiStream',
        sw: sw,
        success: false,
        error: e,
      );
      rethrow;
    }
  }

  Stream<T> _trackStream<T>(
    Stream<T> source,
    RpcMiddlewareContext call,
    String callType,
    Stopwatch sw,
  ) async* {
    try {
      await for (final item in source) {
        yield item;
      }
      _record(call: call, callType: callType, sw: sw, success: true);
    } catch (e) {
      _record(call: call, callType: callType, sw: sw, success: false, error: e);
      rethrow;
    }
  }
}
