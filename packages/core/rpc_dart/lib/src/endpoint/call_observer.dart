// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// How an observed call ended. See [RpcCallObserverInterceptor].
///
/// Open: a minor release may add an outcome, so a `switch` keeps a default.
sealed class RpcCallOutcome {
  const RpcCallOutcome();
}

/// The call completed: a response, or a response stream that ended with no
/// error.
final class RpcCallSucceeded extends RpcCallOutcome {
  /// The outcome of a call that completed.
  const RpcCallSucceeded();

  @override
  String toString() => 'succeeded';
}

/// The call failed with [error].
///
/// For a streamed response this is the last error the stream carried: an error
/// on a stream is not terminal, and the call is over only when the stream is.
final class RpcCallFailed extends RpcCallOutcome {
  /// The outcome of a call that failed with [error].
  const RpcCallFailed(this.error, this.stackTrace);

  /// What the call failed with.
  final Object error;

  /// Where [error] was thrown.
  final StackTrace stackTrace;

  @override
  String toString() => 'failed(${error.runtimeType})';
}

/// The call was cancelled: its consumer cancelled the response stream before
/// it ended, or the call threw [RpcCancelledException].
///
/// A stream that carried an error before it was cancelled ends as
/// [RpcCallFailed] instead.
final class RpcCallCancelled extends RpcCallOutcome {
  /// The outcome of a cancelled call.
  const RpcCallCancelled();

  @override
  String toString() => 'cancelled';
}

/// An interceptor that sees every call start and end, for all four call
/// shapes.
///
/// A subclass implements [onCallStart], which returns the state it keeps for
/// one call, and [onCallEnd], which receives that state once with the
/// [RpcCallOutcome] and the call's duration. For a streamed response the call
/// ends when the stream does: when it is done, or when its consumer cancels
/// it. The stream itself is passed through unchanged, pause and resume
/// included.
///
/// The optional hooks: [observes] picks the calls it sees, [contextFor] changes the context the rest of the chain
/// runs with, [runCall] runs the rest of the chain inside something (a zone),
/// and [onResponseMessage] / [onResponseError] see each event of a streamed
/// response.
///
/// ```dart
/// final class SlowCallLog extends RpcCallObserverInterceptor<String> {
///   @override
///   String onCallStart(RpcCallInfo call, RpcMethodType type) =>
///       '${call.serviceName}.${call.methodName}';
///
///   @override
///   void onCallEnd(String name, RpcCallOutcome outcome, Duration duration) {
///     if (duration > const Duration(seconds: 1)) print('$name took $duration');
///   }
/// }
/// ```
abstract class RpcCallObserverInterceptor<S> extends IRpcInterceptor {
  /// Creates the interceptor.
  const RpcCallObserverInterceptor();

  /// A call of [type] reached this interceptor. Returns the state handed to
  /// every later hook of the same call.
  S onCallStart(RpcCallInfo call, RpcMethodType type);

  /// The call that [onCallStart] returned [state] for is over. Called exactly
  /// once per call.
  void onCallEnd(S state, RpcCallOutcome outcome, Duration duration);

  /// Whether this interceptor observes [call]. A call it does not observe
  /// passes through untouched: no hook is called for it. True by default;
  /// on an `RpcPeerEndpoint`, whose one interceptor list runs both ways, an
  /// observer of one side checks [RpcCallInfo.direction] here.
  bool observes(RpcCallInfo call, RpcMethodType type) => true;

  /// The context the rest of the chain runs with. Unchanged by default.
  RpcContext contextFor(S state, RpcContext context) => context;

  /// Runs [body], the rest of the chain, for [state]. Calls it by default;
  /// override to run it inside a zone. Must return what [body] returns, or
  /// rethrow what it throws.
  Future<T> runCall<T>(S state, Future<T> Function() body) => body();

  /// A message of a streamed response.
  void onResponseMessage(S state) {}

  /// An error on a streamed response. The stream may go on; the call ends
  /// with the last one.
  void onResponseError(S state, Object error, StackTrace stackTrace) {}

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) => _observeResponse(
    call,
    RpcMethodType.unary,
    (context) => next(context, request),
  );

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) => _observeResponse(
    call,
    RpcMethodType.clientStream,
    (context) => next(context, requests),
  );

  @override
  Future<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) => _observeStream(
    call,
    RpcMethodType.serverStream,
    (context) => next(context, request),
  );

  @override
  Future<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) => _observeStream(
    call,
    RpcMethodType.bidirectionalStream,
    (context) => next(context, requests),
  );

  Future<T> _observeResponse<T>(
    RpcCallInfo call,
    RpcMethodType type,
    Future<T> Function(RpcContext context) next,
  ) async {
    if (!observes(call, type)) return next(call.context);
    final state = onCallStart(call, type);
    final clock = Stopwatch()..start();
    try {
      final response = await runCall(
        state,
        () => next(contextFor(state, call.context)),
      );
      onCallEnd(state, const RpcCallSucceeded(), clock.elapsed);
      return response;
    } catch (error, stackTrace) {
      onCallEnd(state, _outcomeOf(error, stackTrace), clock.elapsed);
      rethrow;
    }
  }

  Future<Stream<T>> _observeStream<T>(
    RpcCallInfo call,
    RpcMethodType type,
    FutureOr<Stream<T>> Function(RpcContext context) next,
  ) async {
    if (!observes(call, type)) return next(call.context);
    final state = onCallStart(call, type);
    final clock = Stopwatch()..start();
    final Stream<T> source;
    try {
      source = await runCall(
        state,
        () async => await next(contextFor(state, call.context)),
      );
    } catch (error, stackTrace) {
      onCallEnd(state, _outcomeOf(error, stackTrace), clock.elapsed);
      rethrow;
    }

    var ended = false;
    RpcCallOutcome? lastError;
    void end(RpcCallOutcome outcome) {
      if (ended) return;
      ended = true;
      onCallEnd(state, lastError ?? outcome, clock.elapsed);
    }

    return StreamBridge<T>(
      source: source.map((message) {
        onResponseMessage(state);
        return message;
      }),
      subscribeOnFirstListen: true,
      onSourceError: (error, stackTrace) {
        onResponseError(state, error, stackTrace);
        lastError = _outcomeOf(error, stackTrace);
      },
      onSourceDone: () => end(const RpcCallSucceeded()),
      // Also reached after the stream is done, where [end] is a no-op.
      onConsumerCancel: () => end(const RpcCallCancelled()),
    ).stream;
  }

  static RpcCallOutcome _outcomeOf(Object error, StackTrace stackTrace) =>
      error is RpcCancelledException
      ? const RpcCallCancelled()
      : RpcCallFailed(error, stackTrace);
}
