// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Server-side handler for client streaming: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Consumes a request stream and returns one response.
final class ClientStreamResponder<
  TRequest extends Object,
  TResponse extends Object
>
    implements IRpcResponder {
  late final LogScope _logger;

  @override
  final int id;

  final Completer<void> _doneCompleter = Completer<void>();

  /// Completes when the client stream has fully finished.
  Future<void> get done => _doneCompleter.future;

  void _completeDone() {
    if (_doneCompleter.isCompleted) return;
    _doneCompleter.complete();
  }

  /// Stream processor.
  late final StreamProcessor<TRequest, TResponse> _processor;

  /// True when handler started.
  bool _handlerStarted = false;

  /// Creates a client-stream responder.
  ClientStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    required Future<TResponse> Function(Stream<TRequest> requests) handler,
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

    // Serialization requires codecs.
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError(
        'Codecs are required for serialization mode. '
        'For zero-copy leave codecs null.',
      );
    }

    _logger = logger?.child('ClientResponder') ?? LogScope.noop;
    _logger.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ClientStreamResponder for $serviceName.$methodName [id: $id]',
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
    _logger.internal('Binding to message stream [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  void _setupRequestHandler(
    Future<TResponse> Function(Stream<TRequest> requests) handler,
  ) {
    if (_handlerStarted) {
      _logger.warning('Request handler already started [id: $id]');
      return;
    }

    _handlerStarted = true;
    _logger.internal('Configuring request handler for client stream [id: $id]');

    // Invoke handler directly with the request stream.
    handler(_processor.requests)
        .then((response) async {
          _logger.internal(
            'Handler completed, sending response: $response [id: $id]',
          );

          try {
            await _processor.send(response);
            await _processor.finishSending();
            _logger.internal('Response delivered to client [id: $id]');
          } catch (e, stackTrace) {
            _logger.error(
              'Failed to send response to client [id: $id]',
              error: e,
              stackTrace: stackTrace,
            );
          } finally {
            _completeDone();
          }
        })
        .catchError((error, stackTrace) async {
          _logger.error(
            'Client stream handling failed [id: $id]',
            error: error,
            stackTrace: stackTrace,
          );
          try {
            final wire = wireStatusFor(error);
            await _processor.sendError(
              wire.status,
              wire.message,
              statusDetailsBin: wire.detailsBin,
            );
          } finally {
            _completeDone();
          }
        });
  }

  /// Closes the stream and releases resources.
  @override
  Future<void> close() async {
    await _processor.close();
    _completeDone();
  }
}
