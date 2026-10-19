// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Bidirectional stream caller: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Sends and receives concurrently with no ordering restrictions.
final class BidirectionalStreamCaller<
  TRequest extends Object,
  TResponse extends Object
> {
  late final LogScope _logger;

  /// Stream processor.
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Incoming responses from the server (payload or metadata); completes on
  /// end-of-stream, and surfaces a non-OK grpc-status trailer as an
  /// [RpcStatusException] error rather than completing silently.
  Stream<RpcMessage<TResponse>> get responses => _processor.responses.transform(
    _grpcStatusErrorTransformer(_logger, context: _context),
  );

  final RpcContext? _context;

  /// Creates a bidirectional stream caller.
  BidirectionalStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) : _context = context {
    // The codecs-or-zero-copy rule is checked by the processor.
    final isZeroCopy = requestCodec == null && responseCodec == null;
    _logger = logger?.child('BidirectionalCaller') ?? LogScope.noop;
    if (_logger.isInternal) {
      _logger.internal(
        'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} BidirectionalStreamCaller for $serviceName.$methodName',
      );
    }

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );

    // Announce the call NOW, not on the first request.
    //
    // Bidirectional is the one shape whose caller may legitimately stay silent
    // indefinitely -- a subscription opens the channel and listens. Initial
    // metadata is otherwise sent by the first request or by the half-close, so
    // such a call never reached the responder at all: measured with a handler
    // that pushes five messages, the server reported openStreams=0,
    // activeResponders=0 and the caller hung. Sending zero messages AND
    // half-closing already worked; holding the request stream open did not.
    _processor._queueInitialMetadataIfUnsent();
  }

  /// Sends a request to the server (can be called multiple times).
  Future<void> send(TRequest request) async {
    if (_logger.isInternal) {
      _logger.internal('Sending a request to the bidirectional stream');
    }
    await _processor.send(request);
  }

  /// Finishes sending requests; responses may continue until server completes.
  Future<void> finishSending() async {
    await _processor.finishSending();
  }

  /// Tells the server this call is being abandoned locally, so its handler
  /// stops waiting on a request stream that will never produce again.
  ///
  /// [finishSending] is the healthy counterpart: it half-closes and the
  /// handler's `await for` ends on its own. Abandoning is not half-closing, and
  /// the handler has to be able to tell them apart. A caller whose request
  /// producer fails owns this duty.
  ///
  /// Never throws.
  Future<void> abort(String reason) => _processor.notifyPeerOfAbort(reason);

  /// Closes the stream and releases resources.
  Future<void> close() async {
    _logger.internal('Closing BidirectionalStreamCaller');
    await _processor.close();
  }
}
