// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Ping protocol constants and metadata between endpoints.
abstract final class RpcEndpointPingProtocol {
  /// Service name for ping requests.
  static const String serviceName = '_rpc.System';

  /// Method name for ping requests.
  static const String methodName = 'Ping';

  /// Method key in `service.method` form.
  static const String methodKey = '$serviceName.$methodName';

  /// HTTP/2 path `/Service/Method`.
  static const String methodPath = '/$serviceName/$methodName';

  /// Header with client ping timestamp.
  static const String requestTimestampHeader = 'x-rpc-ping-timestamp';

  /// Header with responder processing timestamp.
  static const String responseTimestampHeader = 'x-rpc-pong-timestamp';

  /// Header with responder endpoint debug label.
  static const String responseDebugLabelHeader = 'x-rpc-pong-endpoint';

  /// Header with responder transport type.
  static const String responseTransportHeader = 'x-rpc-pong-transport';
}

/// Ping result between endpoints.
final class RpcEndpointPingResult {
  /// Timestamp when the ping was sent.
  final DateTime sentAt;

  /// Timestamp when the response was received.
  final DateTime receivedAt;

  /// Full round-trip time.
  final Duration roundTrip;

  /// Responder processing timestamp, if provided.
  final DateTime? responderTimestamp;

  /// Responder endpoint debug label, if provided.
  final String? responderDebugLabel;

  /// Responder transport type, if provided.
  final String? responderTransportType;

  /// Response headers in readable form.
  final Map<String, String> responseHeaders;

  /// Creates a ping result from the given timestamps and metadata.
  RpcEndpointPingResult({
    required this.sentAt,
    required this.receivedAt,
    required this.roundTrip,
    this.responderTimestamp,
    this.responderDebugLabel,
    this.responderTransportType,
    Map<String, String>? responseHeaders,
  }) : responseHeaders = Map.unmodifiable(responseHeaders ?? const {});
}

/// Manages sending a ping and handling its response for an endpoint.
final class RpcEndpointPingExchange {
  /// Transport used to send and receive ping messages.
  final IRpcTransport transport;

  /// Stream ID reserved for this ping exchange.
  final int streamId;

  /// Timestamp when the ping was sent.
  final DateTime sentAt;

  /// Logger for ping lifecycle.
  late final LogScope _log;

  /// Creates an [RpcEndpointPingExchange] for the given transport.
  RpcEndpointPingExchange({
    required this.transport,
    LogScope? logger,
    required this.streamId,
    required this.sentAt,
  }) : _log = logger ?? LogScope.noop;

  /// Sends the ping and waits for the pong response.
  Future<RpcEndpointPingResult> execute({
    required RpcMetadata metadata,
    Duration? timeout,
  }) async {
    final completer = Completer<RpcEndpointPingResult>();
    StreamSubscription<RpcTransportMessage>? subscription;

    Map<String, String> metadataToMap(RpcMetadata metadata) {
      final map = <String, String>{};
      for (final header in metadata.headers) {
        map[header.name] = header.value;
      }
      return map;
    }

    void completeSuccess(RpcEndpointPingResult result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    void completeError(Object error, [StackTrace? stackTrace]) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }

    subscription = transport.getMessagesForStream(streamId).listen(
      (message) {
        if (!message.isMetadataOnly || message.metadata == null) {
          return;
        }

        final headersMap = metadataToMap(message.metadata!);

        if (!headersMap.containsKey(RpcHeaders.grpcStatus)) {
          if (message.isEndOfStream) {
            completeError(
              StateError(
                'Ping stream завершен без трейлеров [streamId: $streamId]',
              ),
            );
            return;
          }

          _log.internal(
            'Получены начальные метаданные ответа ping [streamId: $streamId]',
          );
          return;
        }

        final statusCode = int.tryParse(
              headersMap[RpcHeaders.grpcStatus] ?? '',
            ) ??
            RpcStatus.unknown;

        final receivedAt = DateTime.now().toUtc();

        if (statusCode != RpcStatus.ok) {
          final statusMessage =
              headersMap[RpcHeaders.grpcMessage] ?? 'Unknown error';
          final decodedMessage = RpcMetadata.decodeGrpcMessage(statusMessage);
          _log.warning(
            'Ping завершился с ошибкой: status=$statusCode, message=$decodedMessage [streamId: $streamId]',
          );
          completeError(
            RpcException(
              'Ping failed with status $statusCode: $decodedMessage',
            ),
          );
          return;
        }

        DateTime? responderTimestamp;
        final responderTimestampRaw =
            headersMap[RpcEndpointPingProtocol.responseTimestampHeader];
        if (responderTimestampRaw != null) {
          responderTimestamp = DateTime.tryParse(responderTimestampRaw);
        }

        final result = RpcEndpointPingResult(
          sentAt: sentAt,
          receivedAt: receivedAt,
          roundTrip: receivedAt.difference(sentAt),
          responderTimestamp: responderTimestamp,
          responderDebugLabel:
              headersMap[RpcEndpointPingProtocol.responseDebugLabelHeader],
          responderTransportType:
              headersMap[RpcEndpointPingProtocol.responseTransportHeader],
          responseHeaders: headersMap,
        );

        _log.internal(
          'Ping успешно завершен, RTT=${result.roundTrip.inMilliseconds}мс [streamId: $streamId]',
        );

        completeSuccess(result);
      },
      onError: (error, stackTrace) {
        _log.error(
          'Ошибка при получении ответа ping [streamId: $streamId]',
          error: error,
          stackTrace: stackTrace,
        );
        completeError(error, stackTrace);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completeError(
            StateError(
              'Ping stream завершен без трейлеров [streamId: $streamId]',
            ),
          );
        }
      },
    );

    try {
      _log.internal('Отправка ping запроса [streamId: $streamId]');
      await transport.sendMetadata(
        streamId,
        metadata,
        endStream: true,
      );
    } catch (error, stackTrace) {
      await subscription.cancel();
      _log.error(
        'Ошибка при отправке ping [streamId: $streamId]',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }

    Future<RpcEndpointPingResult> future = completer.future;

    if (timeout != null) {
      future = future.timeout(
        timeout,
        onTimeout: () {
          _log.warning(
            'Ping превысил время ожидания ${timeout.inMilliseconds}мс [streamId: $streamId]',
          );
          throw TimeoutException(
            'Ping не завершился за ${timeout.inMilliseconds}мс',
          );
        },
      );
    }

    try {
      return await future;
    } finally {
      await subscription.cancel();
    }
  }
}
