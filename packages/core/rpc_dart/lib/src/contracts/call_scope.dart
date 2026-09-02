// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Structured concurrency scope for an RPC call.
///
/// Tracks resources (stream subscriptions, cleanup callbacks) and automatically
/// disposes them when the call ends — by success, error, cancellation, or
/// deadline.
///
/// The server injects one scope per incoming call into the handler's context
/// and closes it when the call ends, running registered disposers in LIFO
/// order. Retrieve it inside a responder handler:
/// ```dart
/// Future<Response> myHandler(Request req, {RpcContext? context}) async {
///   final scope = context?.callScope;
///   scope?.onDispose(() => releaseResource());
///   scope?.listen(externalStream, (event) { ... }); // auto-cancelled
///   return Response(...);
/// }
/// ```
/// (Each call processor also owns a separate internal scope for its own
/// transport-level subscriptions.)
final class RpcCallScope {
  final List<FutureOr<void> Function()> _disposers = [];
  final Completer<void> _done = Completer<void>();
  Timer? _deadlineTimer;
  StreamSubscription? _cancellationSub;
  bool _isClosed = false;

  /// The context this scope is bound to (if any).
  final RpcContext? _context;

  /// Where cleanup failures are reported.
  ///
  /// The server injects a context carrying a per-call logger, so a handler's
  /// cleanup failure lands in that call's log. A scope built without a context
  /// has nowhere to report and stays silent.
  LogScope get _log => _context?.log ?? LogScope.noop;

  /// Reports a cancel that rejected, without letting it escape.
  ///
  /// Cancelling a stream runs user code, which may throw. Dropping that future
  /// made it an unhandled async error, and an unhandled async error in the
  /// root zone terminates the isolate -- fatal for a server, from nothing more
  /// than a tracked stream whose cleanup failed.
  void _cancelFailed(Object error, StackTrace stackTrace) {
    _log.error(
      'Tracked stream failed to cancel',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Creates a scope optionally bound to an [RpcContext].
  ///
  /// If the context has a deadline, a Timer auto-closes the scope when it
  /// expires. If it has a cancellation token, the scope closes on cancel.
  RpcCallScope({RpcContext? context}) : _context = context {
    _wireDeadline();
    _wireCancellation();
  }

  /// Whether the scope has been closed.
  bool get isClosed => _isClosed;

  /// Completes when the scope is closed.
  Future<void> get done => _done.future;

  /// Remaining time until deadline, or null if no deadline.
  Duration? get remaining => _context?.remainingTime;

  /// The cancellation token from the bound context (if any).
  RpcCancellationToken? get cancellationToken => _context?.cancellationToken;

  // ---------------------------------------------------------------------------
  // Resource registration
  // ---------------------------------------------------------------------------

  /// Registers a cleanup callback that runs when the scope closes.
  ///
  /// Callbacks execute in reverse registration order (LIFO).
  /// If the scope is already closed, the callback is invoked immediately.
  void onDispose(FutureOr<void> Function() callback) {
    if (_isClosed) {
      // Best-effort: run immediately, don't block.
      Future.microtask(callback);
      return;
    }
    _disposers.add(callback);
  }

  /// Registers [dispose] for [resource] and returns the resource — acquire and
  /// clean-up in one expression, like a scoped `using`/`with`:
  /// ```dart
  /// final tx = scope.use(await db.begin(), (t) => t.rollbackIfOpen());
  /// ```
  /// [dispose] runs (LIFO) when the scope closes (success, error, cancellation,
  /// or deadline).
  T use<T>(T resource, FutureOr<void> Function(T resource) dispose) {
    onDispose(() => dispose(resource));
    return resource;
  }

  /// Wraps [stream] so it auto-cancels when the scope closes.
  ///
  /// Returns a new stream that mirrors [stream] but stops when
  /// this scope is closed.
  Stream<T> track<T>(Stream<T> stream) {
    if (_isClosed) {
      // Return a stream that completes immediately with no events.
      final c = StreamController<T>();
      c.close();
      return c.stream;
    }

    late StreamSubscription<T> sub;
    late StreamController<T> controller;

    controller = StreamController<T>(
      onCancel: () => sub.cancel().catchError(_cancelFailed),
    );

    sub = stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );

    onDispose(() {
      // Not awaited: cancelling a suspended generator can block indefinitely
      // and the scope has to finish closing. Both this and the onCancel above
      // dropped the returned future outright, so a rejected cancel became TWO
      // unhandled async errors -- measured, and enough to kill the isolate.
      unawaited(sub.cancel().catchError(_cancelFailed));
      if (!controller.isClosed) controller.close();
    });

    return controller.stream;
  }

  /// Listens to [stream] and auto-cancels the subscription when
  /// the scope closes. Returns the subscription for manual control.
  StreamSubscription<T> listen<T>(
    Stream<T> stream,
    void Function(T event) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final sub = stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    onDispose(() => sub.cancel());
    return sub;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Closes the scope and runs all disposers in reverse order.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _cancellationSub?.cancel();
    _cancellationSub = null;

    // Run disposers in reverse (LIFO) order.
    for (var i = _disposers.length - 1; i >= 0; i--) {
      try {
        await _disposers[i]();
      } catch (error, stackTrace) {
        // Keep going so every disposer still runs -- one failing cleanup must
        // not strand the rest. But do not make it vanish: this swallowed
        // silently, so a handler's own cleanup failing (a database handle that
        // would not release, a file that would not close) left no trace
        // anywhere at all -- no log, no error, nothing to notice.
        _log.error(
          'Call-scope disposer failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _disposers.clear();

    if (!_done.isCompleted) _done.complete();
  }

  // ---------------------------------------------------------------------------
  // Internal wiring
  // ---------------------------------------------------------------------------

  void _wireDeadline() {
    final deadline = _context?.deadline;
    if (deadline == null) return;

    // deadline != null implies _context != null; use its (injectable) clock.
    final remaining = deadline.difference(_context!.clock());
    if (remaining.isNegative || remaining == Duration.zero) {
      // Already expired — close on next microtask.
      Future.microtask(close);
      return;
    }
    _deadlineTimer = Timer(remaining, close);
  }

  void _wireCancellation() {
    final token = _context?.cancellationToken;
    if (token == null) return;

    if (token.isCancelled) {
      Future.microtask(close);
      return;
    }
    _cancellationSub = token.cancelled.asStream().listen((_) => close());
  }
}
