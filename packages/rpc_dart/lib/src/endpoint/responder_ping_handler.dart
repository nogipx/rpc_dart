// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

final class RpcResponderPingHandler {
  final IRpcTransport transport;
  final RpcLogger logger;
  final String? debugLabel;

  RpcResponderPingHandler({
    required this.transport,
    required this.logger,
    required this.debugLabel,
  });

  Future<void> respond({
    required int streamId,
    required RpcContext context,
    required Future<void> Function() onComplete,
  }) async {
    final responderTimestamp = DateTime.now().toUtc();

    try {
      await transport.sendMetadata(
        streamId,
        RpcMetadata.forServerInitialResponse(),
      );

      final responseHeaders = <RpcHeader>[
        RpcHeader(
          RpcEndpointPingProtocol.responseTimestampHeader,
          responderTimestamp.toIso8601String(),
        ),
        RpcHeader(
          RpcEndpointPingProtocol.responseTransportHeader,
          transport.runtimeType.toString(),
        ),
        RpcHeader(
          RpcConstants.grpcStatusHeader,
          RpcStatus.ok.toString(),
        ),
      ];

      if (debugLabel != null && debugLabel!.isNotEmpty) {
        responseHeaders.add(
          RpcHeader(
            RpcEndpointPingProtocol.responseDebugLabelHeader,
            debugLabel!,
          ),
        );
      }

      await transport.sendMetadata(
        streamId,
        RpcMetadata(responseHeaders),
        endStream: true,
      );

      logger.internal(
        'Ping обработан успешно [streamId: $streamId]',
        rpcContext: context,
      );
    } catch (error, stackTrace) {
      logger.error(
        'Ошибка при обработке ping [streamId: $streamId]',
        rpcContext: context,
        error: error,
        stackTrace: stackTrace,
      );

      try {
        await transport.sendMetadata(
          streamId,
          RpcMetadata([
            RpcHeader(
              RpcConstants.grpcStatusHeader,
              RpcStatus.internal.toString(),
            ),
            RpcHeader(
              RpcConstants.grpcMessageHeader,
              RpcMetadata.encodeGrpcMessage('Ping handling error: $error'),
            ),
          ]),
          endStream: true,
        );
      } catch (sendError, sendStackTrace) {
        logger.error(
          'Не удалось отправить ошибку ping [streamId: $streamId]',
          rpcContext: context,
          error: sendError,
          stackTrace: sendStackTrace,
        );
      }
    } finally {
      await onComplete();
    }
  }
}
