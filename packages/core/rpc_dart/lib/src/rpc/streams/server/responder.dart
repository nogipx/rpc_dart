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
    implements IRpcResponder {
  late final LogScope _logger;

  @override
  final int id;

  final Completer<void> _doneCompleter = Completer<void>();

  /// Completes when the server stream has fully finished.
  Future<void> get done => _doneCompleter.future;

  void _completeDone() {
    if (_doneCompleter.isCompleted) return;
    _doneCompleter.complete();
  }

  /// Stream processor.
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Incoming request subscription.
  StreamSubscription<void>? _subscription;

  /// The bridge over the user handler's response stream.
  ///
  /// The handler stream used to be consumed with a bare `await for`, whose
  /// implicit subscription nothing could reach. [close] therefore had no way to
  /// stop it, and `_processor.send()` returns silently once the processor is
  /// inactive rather than throwing, so the loop's error `break` never fired
  /// either. A long-lived handler kept producing forever after the client
  /// vanished — burning CPU and pinning everything the generator captured, for
  /// the life of the server process. Owning the subscription lets [close] tear
  /// it down and end the generator at its next suspension point.
  StreamBridge<TResponse>? _handlerRelay;

  /// True until [close] runs; guards the response pump.
  bool _isActive = true;

  /// True after the first request is handled.
  bool _requestHandled = false;

  /// Creates a server-stream responder.
  ServerStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    required Stream<TResponse> Function(TRequest request) handler,
    RpcContext? context,
    LogScope? logger,
  }) {
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

    _logger = logger?.child('ServerResponder') ?? LogScope.noop;
    if (_logger.isInternal) {
      _logger.internal(
        'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ServerStreamResponder for $serviceName.$methodName [id: $id]',
      );
    }

    _processor = StreamProcessor<TRequest, TResponse>(
      transport: transport,
      streamId: id,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );

    _setupRequestHandler(handler);
  }

  /// Binds the responder to the endpoint message stream.
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    if (_logger.isInternal) {
      _logger.internal('Binding to message stream [id: $id]');
    }
    _processor.bindToMessageStream(messageStream);
  }

  /// Configures the server-stream request handler.
  void _setupRequestHandler(
    Stream<TResponse> Function(TRequest request) handler,
  ) {
    if (_logger.isInternal) {
      _logger.internal(
        'Configuring request handler for server stream [id: $id]',
      );
    }

    _subscription = _processor.requests.listen(
      (request) async {
        if (_logger.isInternal) {
          _logger.internal(
            'Received request for server stream: $request [id: $id]',
          );
        }

        if (!_requestHandled) {
          if (_logger.isInternal) {
            _logger.internal(
              'Processing first request for server stream [id: $id]',
            );
          }
          _requestHandled = true;

          try {
            final handlerStream = handler(request);
            // ONE record for one event. This was three -- "Invoking request
            // handler", "Handler invoked, response stream received",
            // "Processing response stream from handler" -- around a single
            // synchronous call that cannot fail between them.
            if (_logger.isInternal) {
              _logger.internal('Request handler returned a stream [id: $id]');
            }

            // Relay the handler stream through a bridge we own, so close() can
            // cancel the upstream subscription and end the `await for`. The
            // bridge is also what passes the loop's demand back: without that
            // the relay is an unbounded buffer, and an `async*` handler keeps
            // allocating while a send is in flight.
            final relay = StreamBridge<TResponse>(source: handlerStream);
            _handlerRelay = relay;

            int responseCount = 0;
            await for (var response in relay.stream) {
              if (!_isActive) break;
              responseCount++;
              if (_logger.isInternal) {
                _logger.internal(
                  'Received response #$responseCount from handler: $response [id: $id]',
                );
              }

              try {
                await _processor.send(response);
                if (_logger.isInternal) {
                  _logger.internal(
                    'Response #$responseCount sent to client [id: $id]',
                  );
                }
              } catch (e, stackTrace) {
                _logger.error(
                  'Failed to send response #$responseCount to client [id: $id]',
                  error: e,
                  stackTrace: stackTrace,
                );
                // Client disconnected or processor closed — stop iterating
                // to avoid leaking the handler subscription on broadcast streams.
                break;
              }
            }

            if (_logger.isInternal) {
              _logger.internal(
                'Handler response stream completed, total responses: $responseCount [id: $id]',
              );
            }

            // Finish sending responses.
            await _processor.finishSending();
            if (_logger.isInternal) {
              _logger.internal('Response sending finished [id: $id]');
            }
            _completeDone();
          } catch (error, trace) {
            _logger.error(
              'Request handling failed [id: $id]',
              error: error,
              stackTrace: trace,
            );
            await sendWireError(error, _processor.sendError);
            _completeDone();
          }
        } else {
          if (_logger.isInternal) {
            _logger.internal(
              'Ignoring extra request (first already handled) [id: $id]',
            );
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) async {
        _logger.error(
          'Error in request stream [id: $id]',
          error: error,
          stackTrace: stackTrace,
        );
        // ANSWERED, not just logged. A server stream carries exactly one
        // request, so an error here means none will ever arrive and the handler
        // will never run -- yet this used to end in silence, and the caller
        // waited out its own deadline with nothing to diagnose.
        //
        // Measured with a caller that has codecs against a method registered
        // zero-copy, which is a mode mismatch the processors now report:
        //
        //   unary        status 13, 38 ms      clientStream status 13, 11 ms
        //   bidi         status 13,  6 ms      serverStream SILENCE, 6 s
        //
        // The other three shapes route this already, one way or another; this
        // was the only one that dropped it.
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
      onDone: () {
        if (_logger.isInternal) {
          _logger.internal('Request stream completed [id: $id]');
        }
      },
    );
  }

  /// Closes the stream and releases resources.
  @override
  Future<void> close() async {
    _isActive = false;
    await _subscription?.cancel();

    // Stop pulling from the user's handler. Cancelling ends its generator at
    // the next suspension point; closing the relay unblocks the `await for`
    // that is waiting on it. Neither is awaited: a handler stuck in cancel must
    // not block teardown of the rest of the call.
    final relay = _handlerRelay;
    _handlerRelay = null;
    relay?.close();

    await _processor.close();
    _completeDone();
  }
}
