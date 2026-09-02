// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Client streaming caller: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Sends many requests, receives one response.
final class ClientStreamCaller<
  TRequest extends Object,
  TResponse extends Object
> {
  late final LogScope _logger;

  /// Stream processor.
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Completer with the response.
  final Completer<TResponse> _responseCompleter = Completer<TResponse>();

  /// Subscription to responses.
  StreamSubscription? _subscription;

  /// Marks send completion.
  bool _sendingFinished = false;

  /// Call context, kept so the response wait can honour its deadline.
  ///
  /// Final: a non-final private field of this name would block type promotion
  /// for every other `_context` in the library, since they share it.
  final RpcContext? _context;

  /// Creates a client-stream caller.
  ClientStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) : _context = context {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy requires transport support.
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy mode requires a transport with zero-copy support. '
        'Provide codecs for network transports.',
      );
    }

    // Serialization mode: codecs required.
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError(
        'Codecs are required for serialization mode. '
        'For zero-copy leave codecs null.',
      );
    }

    _logger = logger?.child('ClientCaller') ?? LogScope.noop;
    _logger.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ClientStreamCaller for $serviceName.$methodName',
    );

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );

    _setupResponseHandler();
  }

  /// Configures response handler.
  void _setupResponseHandler() {
    _subscription = _processor.responses.listen(
      (rpcMessage) {
        _logger.internal(
          'Received response from server: isMetadataOnly=${rpcMessage.isMetadataOnly}, isEndOfStream=${rpcMessage.isEndOfStream}',
        );

        // Check for errors in metadata/trailers.
        if (rpcMessage.isMetadataOnly && rpcMessage.metadata != null) {
          final statusCode = rpcMessage.metadata!.getHeaderValue(
            RpcHeaders.grpcStatus,
          );
          _logger.internal('Status code from metadata: $statusCode');

          if (statusCode != null && statusCode != '0') {
            final errorMessage =
                rpcMessage.metadata!.getHeaderValue(RpcHeaders.grpcMessage) ??
                '';
            final decodedMessage = RpcMetadata.decodeGrpcMessage(errorMessage);
            _logger.error(
              'Received error status code: $statusCode - $decodedMessage',
            );

            if (!_responseCompleter.isCompleted) {
              _responseCompleter.completeError(
                RpcStatusException.fromTrailer(
                  int.tryParse(statusCode) ?? RpcStatus.unknown,
                  decodedMessage,
                  detailsBin: rpcMessage.metadata!.statusDetailsBin,
                ),
              );
            }
            return;
          }

          // If final status OK (0) but no payload, fail because data was expected.
          if (statusCode == '0' &&
              rpcMessage.isEndOfStream &&
              !_responseCompleter.isCompleted) {
            _logger.warning('Status OK but no response payload');
            _responseCompleter.completeError(
              RpcStatusException(
                RpcStatus.internal,
                'Stream closed without response payload',
              ),
            );
          }
        }

        // Handle responses with payload.
        if (!rpcMessage.isMetadataOnly &&
            !_responseCompleter.isCompleted &&
            rpcMessage.payload != null) {
          _logger.internal('Received payload: ${rpcMessage.payload}');
          _responseCompleter.complete(rpcMessage.payload!);
        }
      },
      onError: (error, stackTrace) {
        _logger.error(
          'Error in response stream',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_responseCompleter.isCompleted) {
          _responseCompleter.completeError(error, stackTrace);
        }
      },
      onDone: () {
        _logger.internal('Response stream completed');
        if (!_responseCompleter.isCompleted) {
          // Might be transport close; surface error if still pending.
          try {
            // Our own deadline takes precedence over whatever the transport
            // reports as it collapses. The server tears its stream down when
            // the same deadline passes, which closes this stream at almost the
            // same instant -- and reporting UNAVAILABLE for that is a race:
            // whichever landed first decided the caller's exception type.
            // If the deadline has passed, the deadline is why the call failed.
            final deadline = _context?.deadline;
            _responseCompleter.completeError(
              deadline != null && (_context?.isExpired ?? false)
                  ? RpcDeadlineExceededException(deadline, Duration.zero)
                  : RpcStatusException(
                      RpcStatus.unavailable,
                      'Stream closed without receiving response',
                    ),
            );
          } catch (e) {
            // If completer already finished, ignore.
            _logger.internal('Completer already completed, skipping error: $e');
          }
        }
      },
    );
  }

  /// Sends a request into the stream. Safe to call multiple times until finishSending().
  Future<void> send(TRequest request) async {
    if (_sendingFinished) {
      throw StateError(
        'Sending already completed. Call finishSending() to get the response.',
      );
    }

    _logger.internal('Sending request to client stream: $request');
    await _processor.send(request);
  }

  /// Default bound on the response wait for a call with no deadline of its own.
  static const Duration _noDeadlineFallback = Duration(seconds: 60);

  /// Completes sending requests and waits for a single response.
  ///
  /// Returns the single server response. The wait is bounded by the context
  /// deadline when one is set, and by [_noDeadlineFallback] otherwise — the
  /// same rule [UnaryCaller] applies.
  ///
  /// The fallback used to apply unconditionally, so a deadline LONGER than it
  /// was silently truncated: measured against a server that never responds, a
  /// 90s deadline ended the unary call at 90s and the client-stream call at
  /// 60s. A streaming upload given ten minutes died after one.
  Future<TResponse> finishSending() async {
    if (_sendingFinished) {
      throw StateError('Sending was already completed earlier.');
    }

    _sendingFinished = true;

    try {
      // Finish sending requests.
      await _processor.finishSending();
      _logger.internal('Send complete, waiting for response');

      // Computed here, not at construction: requests may have taken a while to
      // send, and remainingTime already accounts for that.
      final deadline = _context?.deadline;
      final wait = _context?.remainingTime ?? _noDeadlineFallback;

      // Await single response with timeout.
      return await _responseCompleter.future.timeout(
        wait,
        onTimeout: () {
          _logger.error('Response wait timed out after $wait');
          // Free resources on timeout.
          unawaited(close());
          // With a deadline set, two things race to end the call: the call
          // scope pushes RpcDeadlineExceededException onto the response
          // completer, and this timeout fires. Reporting a TimeoutException
          // from here made the exception type depend on which won -- observed
          // both ways for the same 500ms deadline across runs. Report the
          // deadline as a deadline either way.
          if (deadline != null) {
            throw RpcDeadlineExceededException(deadline, wait);
          }
          throw TimeoutException('Response wait timeout from server', wait);
        },
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to finish sending',
        error: e,
        stackTrace: stackTrace,
      );

      if (!_responseCompleter.isCompleted) {
        _responseCompleter.completeError(e, stackTrace);
      }

      // Free resources and close transport.
      unawaited(close());
      rethrow;
    }
  }

  /// Convenience: send a request stream and return the single response (auto-closes).
  ///
  /// Aborts as soon as EITHER the request stream is drained or the call itself
  /// fails. That second half used to be missing: the body was
  /// `await for (final r in requests) { await send(r); }`, and a deadline or a
  /// cancellation is delivered on the RESPONSE path, which that loop never
  /// reached. A client stream whose producer stalled therefore ignored both
  /// entirely -- measured with the request stream left open, a 1s deadline and
  /// a cancellation at 500ms each hung past 4s, while the same call with the
  /// stream closed returned in 37ms.
  Future<TResponse> call(Stream<TRequest> requests) async {
    _logger.internal('Executing client stream call');

    final drained = Completer<void>();
    // Listening rather than `await for` gives us a subscription to cancel when
    // the call ends early. Ordering is unaffected: send() queues the write
    // synchronously onto the processor's send sequence, so it is only the
    // queueing that is asynchronous.
    final requestSub = requests.listen(
      (request) {
        if (_sendingFinished) return;
        _logger.internal('Sending request: $request');
        unawaited(
          send(request).catchError((Object e, StackTrace st) {
            if (!drained.isCompleted) drained.completeError(e, st);
          }),
        );
      },
      onError: (Object e, StackTrace st) {
        if (!drained.isCompleted) drained.completeError(e, st);
      },
      onDone: () {
        if (!drained.isCompleted) drained.complete();
      },
    );

    try {
      // Whichever settles first wins: the request stream draining, or the call
      // failing. _responseCompleter carries the deadline and cancellation
      // errors that the request side cannot observe. Future.any consumes the
      // loser's result, so a late error on the other future is not unhandled.
      await Future.any<void>([drained.future, _responseCompleter.future]);

      _logger.internal('Request stream finished, awaiting response');

      // Finish sending and get the response.
      return await finishSending();
    } catch (e) {
      _logger.error('Client stream call failed', error: e);
      rethrow;
    } finally {
      // Not awaited: cancelling a stalled producer can block indefinitely, and
      // the call is already over.
      unawaited(requestSub.cancel().catchError((_) {}));
      await close();
    }
  }

  /// Closes the stream and releases resources.
  Future<void> close() async {
    _logger.internal('Closing ClientStreamCaller');
    await _subscription?.cancel();
    await _processor.close();
  }
}
