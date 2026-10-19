// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'call_event_interceptor.dart';
import 'rpc_app_config.dart';

/// An interceptor that records every RPC call for later inspection.
///
/// Attach to [RpcTestApp] or [RpcApp] to capture calls during tests, then
/// assert on [entries], [callsTo], [callCount], etc. Each entry is the
/// [RpcCallEvent] of one call that ended: succeeded, failed or cancelled.
///
/// **Retention.** By default every call is kept forever, which is what a test
/// wants and what a long-running server cannot afford: each [RpcCallEvent]
/// holds the call's `RpcContext`, so an unbounded spy on a live server pins
/// one context graph per call for the life of the process. Pass [maxEntries]
/// to keep only the most recent N (older entries are dropped as new ones
/// arrive), or call [reset] periodically.
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
class RpcCallSpy extends CallEventInterceptor {
  /// Creates a spy.
  ///
  /// [maxEntries] caps retention: once that many entries are held, recording a
  /// new one drops the oldest. `null` (the default) keeps everything. Must be
  /// positive when provided.
  RpcCallSpy({this.maxEntries})
    : assert(
        maxEntries == null || maxEntries > 0,
        'maxEntries must be positive',
      );

  /// Maximum entries retained, or null for unbounded.
  final int? maxEntries;

  final List<RpcCallEvent> _entries = [];

  /// All recorded entries in the order the calls ended.
  List<RpcCallEvent> get entries => List.unmodifiable(_entries);

  /// Total number of recorded calls.
  int get callCount => _entries.length;

  /// Number of calls that completed.
  int get successCount => _entries.where((e) => e.success).length;

  /// Number of calls that failed. Cancelled calls are neither successes nor
  /// errors.
  int get errorCount => _entries.where((e) => e.error != null).length;

  /// All entries for the given [service] and [method].
  List<RpcCallEvent> callsTo(String service, String method) => _entries
      .where((e) => e.serviceName == service && e.methodName == method)
      .toList();

  /// Whether [service].[method] was called at least once.
  bool wasCalled(String service, String method) =>
      _entries.any((e) => e.serviceName == service && e.methodName == method);

  /// Removes all recorded entries.
  void reset() => _entries.clear();

  @override
  void onEvent(RpcCallEvent event) {
    _entries.add(event);

    // Drop the oldest once the cap is reached. Each entry pins the call's
    // RpcContext, so an uncapped spy on a live server retains one context
    // graph per call for the life of the process.
    final cap = maxEntries;
    if (cap != null && _entries.length > cap) {
      _entries.removeRange(0, _entries.length - cap);
    }
  }
}
