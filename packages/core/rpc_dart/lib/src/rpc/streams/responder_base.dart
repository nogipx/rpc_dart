// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// What every responder shares: the processor of its stream, the stream id,
/// [done], binding and teardown. Codecs → serialized; no codecs → zero-copy,
/// which the processor checks.
abstract base class RpcResponderBase<
  TRequest extends Object,
  TResponse extends Object
>
    implements IRpcResponder {
  /// Creates the responder's processor for stream [id]. [logName] is the
  /// child scope of [logger]; [className] names the responder in the log, as
  /// `runtimeType` is mangled in obfuscated builds.
  RpcResponderBase({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
    bool compressResponses = false,
    required String logName,
    required String className,
  }) : _logger = logger?.child(logName) ?? LogScope.noop {
    if (_logger.isInternal) {
      final mode = requestCodec == null && responseCodec == null
          ? 'Zero-copy'
          : 'Serialized';
      _logger.internal(
        'Creating $mode $className for $serviceName.$methodName [id: $id]',
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
      compressResponses: compressResponses,
    );
  }

  @override
  final int id;

  final LogScope _logger;

  late final StreamProcessor<TRequest, TResponse> _processor;

  final Completer<void> _doneCompleter = Completer<void>();

  @override
  Future<void> get done => _doneCompleter.future;

  void _completeDone() {
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  /// True until [close] runs.
  bool get _isActive => _closing == null;

  Future<void>? _closing;

  @override
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    if (_logger.isInternal) {
      _logger.internal('Binding to message stream [id: $id]');
    }
    _processor.bindToMessageStream(messageStream);
  }

  /// The bridge over the handler's response stream while [_relay] runs.
  StreamBridge<TResponse>? _handlerRelay;

  /// Sends the handler's [responses] as they come and returns how many went
  /// out. An error from the handler's stream propagates; a send that fails
  /// ends the relay, and the finish after it answers the call.
  ///
  /// Through a bridge this responder owns, so [close] can cancel the handler
  /// and end the loop; a bare `await for` keeps a subscription nothing can
  /// reach, and a long-lived handler keeps producing after the client left.
  /// The bridge also hands the loop's demand back: without it the relay is an
  /// unbounded buffer, since an `async*` handler keeps allocating while a send
  /// is in flight.
  Future<int> _relay(Stream<TResponse> responses) async {
    final relay = StreamBridge<TResponse>(source: responses);
    _handlerRelay = relay;
    unawaited(done.whenComplete(relay.close));
    var sent = 0;
    try {
      await for (final response in relay.stream) {
        if (!_isActive) break;
        try {
          await _processor.send(response);
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to send response #${sent + 1} [id: $id]',
            error: e,
            stackTrace: stackTrace,
          );
          break;
        }
        sent++;
        // A response that could not go out ends the call; the handler must
        // not keep producing behind it.
        if (_processor.isAnswered) break;
      }
    } finally {
      relay.close();
    }
    if (_logger.isInternal) {
      _logger.internal('Handler responses relayed: $sent [id: $id]');
    }
    return sent;
  }

  /// Closes the call. A second call waits for the first to finish.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _stopHandler();
    // Stop pulling from the handler. Cancelling ends its generator at the
    // next suspension point; closing the relay unblocks the loop waiting on
    // it. Not awaited: a handler stuck in cancel must not block teardown.
    final relay = _handlerRelay;
    _handlerRelay = null;
    relay?.close();
    await _processor.close();
    _completeDone();
  }

  /// Stops what the responder runs beside its processor, before the
  /// processor closes.
  Future<void> _stopHandler() async {}
}
