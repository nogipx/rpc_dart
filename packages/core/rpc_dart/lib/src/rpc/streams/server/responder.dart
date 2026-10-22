// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Server-stream responder: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Handles one request and streams responses.
final class ServerStreamResponder<
  TRequest extends Object,
  TResponse extends Object
>
    extends RpcResponderBase<TRequest, TResponse> {
  /// Incoming request subscription.
  StreamSubscription<void>? _subscription;

  /// True once the request is answered: served, refused or failed.
  bool _requestHandled = false;

  /// The request, held until the request stream ends.
  ///
  /// The handler runs only on a request the peer has finished, as grpc-go's
  /// does: a tail or a second message after it is refused before the handler
  /// has run, instead of after its side effects.
  TRequest? _pendingRequest;

  /// Creates a server-stream responder.
  ServerStreamResponder({
    required super.id,
    required super.transport,
    required super.serviceName,
    required super.methodName,
    super.requestCodec,
    super.responseCodec,
    required Stream<TResponse> Function(TRequest request) handler,
    super.context,
    super.logger,
    super.compressResponses,
  }) : super(logName: 'ServerResponder', className: 'ServerStreamResponder') {
    _setupRequestHandler((request) => _serve(request, handler));
  }

  /// The unary responder: a server stream of exactly one response.
  ///
  /// The request is held until the request stream ends; a second one is
  /// refused INTERNAL and a call that carried none INVALID_ARGUMENT. The
  /// handler's future is answered directly, with no stream to relay.
  ServerStreamResponder.unary({
    required super.id,
    required super.transport,
    required super.serviceName,
    required super.methodName,
    super.requestCodec,
    super.responseCodec,
    required FutureOr<TResponse> Function(TRequest request) handler,
    super.context,
    super.logger,
    super.compressResponses,
  }) : super(logName: 'ServerResponder', className: 'ServerStreamResponder') {
    _setupRequestHandler((request) => _serveOne(request, handler));
  }

  /// Configures the server-stream request handler; [serve] answers the
  /// request once the request stream has ended.
  void _setupRequestHandler(Future<void> Function(TRequest request) serve) {
    if (_logger.isInternal) {
      _logger.internal(
        'Configuring request handler for server stream [id: $id]',
      );
    }

    _subscription = _processor.requests.listen(
      (request) async {
        if (_logger.isInternal) {
          _logger.internal('Received a request [id: $id]');
        }

        if (!_requestHandled && _pendingRequest == null) {
          _pendingRequest = request;
          return;
        }
        // A server stream carries ONE request; another fails the call, and
        // the handler still producing for it is stopped.
        if (!_isActive) return;
        _requestHandled = true;
        _pendingRequest = null;
        try {
          await sendWireError(tooManyMessages('request'), _processor.sendError);
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to refuse a second request [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
        } finally {
          await close();
        }
      },
      onError: (Object error, StackTrace stackTrace) async {
        // Faults only, as the handler path above does: a malformed request is
        // the peer's (INVALID_ARGUMENT, answered below), and logging it at
        // error would let a peer write one record per call.
        if (isFaultError(error)) {
          _logger.error(
            'Error in request stream [id: $id]',
            error: error,
            stackTrace: stackTrace,
          );
        }
        // ANSWERED, not just logged. A server stream carries exactly one
        // request, so an error here means none will ever arrive and the handler
        // will never run. Without an answer the caller waits out its own
        // deadline with nothing to diagnose.
        if (_requestHandled || !_isActive) return;
        _requestHandled = true;
        // An `async` listen callback nobody awaits: a throw here would reach
        // the zone, and a server without a zone handler exits on that.
        try {
          await sendWireError(error, _processor.sendError);
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to report the request-stream error to the peer [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
        } finally {
          _completeDone();
        }
      },
      onDone: () async {
        if (_logger.isInternal) {
          _logger.internal('Request stream completed [id: $id]');
        }
        if (_requestHandled || !_isActive) return;
        _requestHandled = true;
        final request = _pendingRequest;
        if (request != null) {
          _pendingRequest = null;
          await serve(request);
          return;
        }
        // A payload frame that decoded to no message (an empty one) bound this
        // responder, so the pipeline's own "no payload" refusal does not
        // apply. Ending here with no request means the handler will never
        // run; without an answer the call holds its slot until disconnect.
        try {
          await sendWireError(
            RpcStatusException(
              RpcStatus.invalidArgument,
              'Request stream closed without a request message',
            ),
            _processor.sendError,
          );
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to refuse a call with no request [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
        } finally {
          _completeDone();
        }
      },
    );
  }

  /// Runs [handler] on [request] and sends its one response.
  Future<void> _serveOne(
    TRequest request,
    FutureOr<TResponse> Function(TRequest request) handler,
  ) async {
    try {
      final response = await handler(request);
      if (_isActive) {
        try {
          await _processor.send(response);
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to send the response to client [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }
      await _processor.finishSending();
      _completeDone();
    } catch (error, trace) {
      if (isFaultError(error)) {
        _logger.error(
          'Request handling failed [id: $id]',
          error: error,
          stackTrace: trace,
        );
      }
      await sendWireError(error, _processor.sendError);
      _completeDone();
    }
  }

  /// Runs [handler] on [request] and streams its responses.
  Future<void> _serve(
    TRequest request,
    Stream<TResponse> Function(TRequest request) handler,
  ) async {
    try {
      final handlerStream = handler(request);
      if (_logger.isInternal) {
        _logger.internal('Request handler returned a stream [id: $id]');
      }

      await _relay(handlerStream);
      await _processor.finishSending();
      if (_logger.isInternal) {
        _logger.internal('Response sending finished [id: $id]');
      }
      _completeDone();
    } catch (error, trace) {
      if (isFaultError(error)) {
        _logger.error(
          'Request handling failed [id: $id]',
          error: error,
          stackTrace: trace,
        );
      }
      await sendWireError(error, _processor.sendError);
      _completeDone();
    }
  }

  @override
  Future<void> _stopHandler() async {
    await _subscription?.cancel();
  }
}
