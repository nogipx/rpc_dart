// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Константы и метаданные протокола ping между эндпоинтами.
abstract final class RpcEndpointPingProtocol {
  /// Имя служебного сервиса для ping запросов.
  static const String serviceName = '_rpc.System';

  /// Имя служебного метода для ping запросов.
  static const String methodName = 'Ping';

  /// Полный ключ метода (service.method).
  static const String methodKey = '$serviceName.$methodName';

  /// HTTP/2 путь метода /Service/Method.
  static const String methodPath = '/$serviceName/$methodName';

  /// Заголовок с отметкой времени отправки ping от клиента.
  static const String requestTimestampHeader = 'x-rpc-ping-timestamp';

  /// Заголовок с отметкой времени обработки ping на стороне responder.
  static const String responseTimestampHeader = 'x-rpc-pong-timestamp';

  /// Заголовок с debug label responder эндпоинта.
  static const String responseDebugLabelHeader = 'x-rpc-pong-endpoint';

  /// Заголовок с типом транспорта responder эндпоинта.
  static const String responseTransportHeader = 'x-rpc-pong-transport';
}

/// Результат ping-запроса между эндпоинтами.
final class RpcEndpointPingResult {
  /// Время отправки ping-запроса.
  final DateTime sentAt;

  /// Время получения ответа.
  final DateTime receivedAt;

  /// Полный круговой трип (RTT) ping-запроса.
  final Duration roundTrip;

  /// Отметка времени обработки ping на responder, если была передана.
  final DateTime? responderTimestamp;

  /// Debug label responder эндпоинта, если указан.
  final String? responderDebugLabel;

  /// Тип транспорта responder эндпоинта, если передан.
  final String? responderTransportType;

  /// Все заголовки ответа в удобном для чтения формате.
  final Map<String, String> responseHeaders;

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

/// Управляет отправкой ping-запроса и обработкой ответа для эндпоинта.
final class RpcEndpointPingExchange {
  final IRpcTransport transport;
  final RpcLogger logger;
  final int streamId;
  final DateTime sentAt;

  RpcEndpointPingExchange({
    required this.transport,
    required this.logger,
    required this.streamId,
    required this.sentAt,
  });

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

        if (!headersMap.containsKey(RpcConstants.grpcStatusHeader)) {
          if (message.isEndOfStream) {
            completeError(
              StateError(
                'Ping stream завершен без трейлеров [streamId: $streamId]',
              ),
            );
            return;
          }

          logger.internal(
            'Получены начальные метаданные ответа ping [streamId: $streamId]',
          );
          return;
        }

        final statusCode = int.tryParse(
              headersMap[RpcConstants.grpcStatusHeader] ?? '',
            ) ??
            RpcStatus.unknown;

        final receivedAt = DateTime.now().toUtc();

        if (statusCode != RpcStatus.ok) {
          final statusMessage =
              headersMap[RpcConstants.grpcMessageHeader] ?? 'Unknown error';
          final decodedMessage = RpcMetadata.decodeGrpcMessage(statusMessage);
          logger.warning(
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

        logger.internal(
          'Ping успешно завершен, RTT=${result.roundTrip.inMilliseconds}мс [streamId: $streamId]',
        );

        completeSuccess(result);
      },
      onError: (error, stackTrace) {
        logger.error(
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
      logger.internal('Отправка ping запроса [streamId: $streamId]');
      await transport.sendMetadata(
        streamId,
        metadata,
        endStream: true,
      );
    } catch (error, stackTrace) {
      await subscription.cancel();
      logger.error(
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
          logger.warning(
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
