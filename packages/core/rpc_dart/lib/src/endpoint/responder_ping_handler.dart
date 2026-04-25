// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Handles incoming ping requests on the responder side.
final class RpcResponderPingHandler {
  /// Transport used to send the ping response.
  final IRpcTransport transport;

  /// Logger for ping handler events.
  final RpcLogger logger;

  /// Debug label included in ping responses.
  final String? debugLabel;

  /// Creates an [RpcResponderPingHandler] with the given transport and logger.
  RpcResponderPingHandler({
    required this.transport,
    required this.logger,
    required this.debugLabel,
  });

  /// Sends a ping response for the given [streamId].
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
          RpcHeaders.grpcStatus,
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
              RpcHeaders.grpcStatus,
              RpcStatus.internal.toString(),
            ),
            RpcHeader(
              RpcHeaders.grpcMessage,
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
