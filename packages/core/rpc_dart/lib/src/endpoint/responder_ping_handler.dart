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
  final LogScope _log;

  /// Debug label included in ping responses.
  final String? debugLabel;

  /// Creates an [RpcResponderPingHandler] with the given transport and logger.
  RpcResponderPingHandler({
    required this.transport,
    LogScope? logger,
    required this.debugLabel,
  }) : _log = logger ?? LogScope.noop;

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
        RpcHeader(RpcHeaders.grpcStatus, RpcStatus.ok.toString()),
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

      if (_log.isInternal) {
        _log.internal('Ping handled successfully [streamId: $streamId]');
      }
    } catch (error, stackTrace) {
      _log.error(
        'Error handling ping [streamId: $streamId]',
        error: error,
        stackTrace: stackTrace,
      );

      try {
        // Through wireStatusFor: the error's own text stays here, logged
        // above, and the peer gets only what the gate lets out.
        final wire = wireStatusFor(error);
        await transport.sendMetadata(
          streamId,
          RpcMetadata.forTrailer(
            wire.status,
            message: wire.message,
            statusDetailsBin: wire.detailsBin,
            maxMessageLength: _trailerMessageCap(transport),
          ),
          endStream: true,
        );
      } catch (sendError, sendStackTrace) {
        _log.error(
          'Failed to send ping error [streamId: $streamId]',
          error: sendError,
          stackTrace: sendStackTrace,
        );
      }
    } finally {
      await onComplete();
    }
  }
}
