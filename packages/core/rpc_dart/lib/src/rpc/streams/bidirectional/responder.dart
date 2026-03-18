// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Bidirectional stream responder: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Handles incoming requests and sends responses independently.
final class BidirectionalStreamResponder<TRequest extends Object,
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

  /// Responder activity flag.
  bool _isActive = true;

  /// Creates a bidirectional stream responder.
  BidirectionalStreamResponder({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
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

    _logger = logger?.child('BidirectionalResponder');
    _logger?.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} BidirectionalStreamResponder for $serviceName.$methodName [id: $id]',
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

    // Response forwarding is initialized only when needed.
  }

  /// Incoming requests from the client; completes when the client closes its side.
  Stream<TRequest> get requests => _processor.requests;

  /// Convenience sink to send responses (forwards to send()).
  StreamSink<TResponse> get responseSink {
    _initResponseForwarding();
    return _responseController.sink;
  }

  /// Controller for outgoing responses.
  final StreamController<TResponse> _responseController =
      StreamController<TResponse>();

  /// Subscription for outgoing responses.
  StreamSubscription? _responseSubscription;

  /// Initializes response forwarding.
  void _initResponseForwarding() {
    if (_responseSubscription != null) return;

    _responseSubscription = _responseController.stream.listen(
      (response) async {
        try {
          await _processor.send(
            response,
          ); // Use processor directly to avoid cyclic dependency.
          _logger?.internal('Response sent via responseSink [id: $id]');
        } catch (e, stackTrace) {
          _logger?.error(
            'Failed to send response via responseSink [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onDone: () async {
        _logger?.internal('Response stream completed [id: $id]');
        await finishReceiving();
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Error in response stream [id: $id]',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Binds the responder to the endpoint message stream.
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    _logger?.internal('Binding to message stream [id: $id]');
    _processor.bindToMessageStream(messageStream);
  }

  /// Sends a response to the client.
  Future<void> send(TResponse response) async {
    if (!_isActive) {
      _logger?.warning(
        'Attempted to send response on inactive responder [id: $id]',
      );
      return;
    }

    await _processor.send(response);
  }

  /// Sends an error to the client.
  Future<void> sendError(int statusCode, String message) async {
    if (!_isActive) return;

    try {
      await _processor.sendError(statusCode, message);
    } finally {
      _completeDone();
    }
  }

  /// Finishes sending responses; call when server has no more responses.
  Future<void> finishReceiving() async {
    if (!_isActive) return;

    try {
      await _processor.finishSending();
    } finally {
      _completeDone();
    }
  }

  /// Closes the stream and releases resources.
  Future<void> close() async {
    if (!_isActive) return;

    _isActive = false;
    await _responseSubscription?.cancel();
    if (!_responseController.isClosed) {
      _responseController.close(); // Do not await completion.
    }
    await _processor.close();
    _completeDone();
  }
}
