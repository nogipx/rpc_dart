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

  /// Closes the call. A second call waits for the first to finish.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await _stopHandler();
    await _processor.close();
    _completeDone();
  }

  /// Stops what the responder runs beside its processor, before the
  /// processor closes.
  Future<void> _stopHandler() async {}
}
