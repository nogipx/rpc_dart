// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Server-stream responder: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Handles one request and streams responses.
final class ServerStreamResponder<TRequest extends Object,
    TResponse extends Object> implements IRpcResponder {
  late final RpcLogger? _logger;

  @override
  final int id;

  final Completer<void> _doneCompleter = Completer<void>();

  Future<void> get done => _doneCompleter.future;

  void _completeDone() {
    if (_doneCompleter.isCompleted) return;
    _doneCompleter.complete();
  }

  /// Stream processor.
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// Incoming request subscription.
  StreamSubscription? _subscription;

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
    RpcLogger? logger,
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

    _logger = logger?.child('ServerResponder');
    _logger?.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ServerStreamResponder for $serviceName.$methodName [id: $id]',
    );

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
    _logger?.internal('Binding to message stream [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  /// Configures the server-stream request handler.
  void _setupRequestHandler(
    Stream<TResponse> Function(TRequest request) handler,
  ) {
    _logger?.internal(
      'Configuring request handler for server stream [id: $id]',
    );

    _subscription = _processor.requests.listen(
      (request) async {
        _logger?.internal(
          'Received request for server stream: $request [id: $id]',
        );

        if (!_requestHandled) {
          _logger?.internal(
            'Processing first request for server stream [id: $id]',
          );
          _requestHandled = true;

          try {
            _logger?.internal('Invoking request handler [id: $id]');
            final handlerStream = handler(request);
            _logger?.internal(
              'Handler invoked, response stream received [id: $id]',
            );

            _logger?.internal(
              'Processing response stream from handler [id: $id]',
            );

            int responseCount = 0;
            await for (var response in handlerStream) {
              responseCount++;
              _logger?.internal(
                'Received response #$responseCount from handler: $response [id: $id]',
              );

              try {
                await _processor.send(response);
                _logger?.internal(
                  'Response #$responseCount sent to client [id: $id]',
                );
              } catch (e, stackTrace) {
                _logger?.error(
                  'Failed to send response #$responseCount to client [id: $id]',
                  error: e,
                  stackTrace: stackTrace,
                );
              }
            }

            _logger?.internal(
              'Handler response stream completed, total responses: $responseCount [id: $id]',
            );

            // Finish sending responses.
            await _processor.finishSending();
            _logger?.internal('Response sending finished [id: $id]');
            _completeDone();
          } catch (error, trace) {
            _logger?.error(
              'Request handling failed [id: $id]',
              error: error,
              stackTrace: trace,
            );
            await _processor.sendError(RpcStatus.internal, error.toString());
            _completeDone();
          }
        } else {
          _logger?.internal(
            'Ignoring extra request (first already handled) [id: $id]',
          );
        }
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Error in request stream [id: $id]',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _logger?.internal('Request stream completed [id: $id]');
      },
    );
  }

  /// Closes the stream and releases resources.
  Future<void> close() async {
    await _subscription?.cancel();
    await _processor.close();
    _completeDone();
  }
}
