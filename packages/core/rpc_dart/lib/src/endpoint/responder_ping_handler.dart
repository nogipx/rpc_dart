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

  static final _okStatus = RpcHeader(
    RpcHeaders.grpcStatus,
    '${RpcStatus.ok.code}',
  );

  /// Sends a ping response for the given [streamId]: one trailer, with no
  /// response headers before it (gRPC's Trailers-Only), carrying this side's
  /// clock and [debugLabel].
  Future<void> respond({
    required int streamId,
    required Future<void> Function() onComplete,
  }) async {
    try {
      // Percent-encoded like `grpc-message`: the label is the application's
      // own text, and a header value the policy refuses fails the whole
      // response. One that does not fit even encoded is left out -- the label
      // is advisory, the pong is not.
      final raw = debugLabel;
      final encoded = raw == null || raw.isEmpty
          ? ''
          : RpcMetadata.encodeGrpcMessage(raw);
      final label =
          encoded.isNotEmpty &&
              transport.securityPolicy.isValidHeaderValue(encoded)
          ? encoded
          : null;
      await transport.sendMetadata(
        streamId,
        RpcMetadata([
          _okStatus,
          RpcHeader(
            RpcEndpointPingProtocol.responseTimestampHeader,
            DateTime.now().microsecondsSinceEpoch.toString(),
          ),
          if (label != null)
            RpcHeader(RpcEndpointPingProtocol.responseDebugLabelHeader, label),
        ]),
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
        // The error's own text stays here, logged above, and the peer gets
        // only what wireStatusFor lets out.
        await transport.sendMetadata(
          streamId,
          RpcTrailers.forError(
            error,
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
