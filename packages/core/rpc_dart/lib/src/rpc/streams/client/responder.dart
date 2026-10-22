// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Server-side handler for client streaming: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Consumes a request stream and returns one response.
final class ClientStreamResponder<
  TRequest extends Object,
  TResponse extends Object
>
    extends RpcResponderBase<TRequest, TResponse> {
  /// Creates a client-stream responder.
  ClientStreamResponder({
    required super.id,
    required super.transport,
    required super.serviceName,
    required super.methodName,
    super.requestCodec,
    super.responseCodec,
    required Future<TResponse> Function(Stream<TRequest> requests) handler,
    super.context,
    super.logger,
    super.compressResponses,
  }) : super(logName: 'ClientResponder', className: 'ClientStreamResponder') {
    _serve(handler);
  }

  /// Runs [handler] on the request stream and answers its result. A handler
  /// that finishes after the call was torn down (the peer cancelled, the
  /// deadline passed) has nobody to answer.
  void _serve(Future<TResponse> Function(Stream<TRequest> requests) handler) {
    if (_logger.isInternal) {
      _logger.internal(
        'Configuring request handler for client stream [id: $id]',
      );
    }

    handler(_processor.requests)
        .then((response) async {
          if (!_isActive) {
            if (_logger.isInternal) {
              _logger.internal(
                'Handler completed after the call ended; response dropped '
                '[id: $id]',
              );
            }
            _completeDone();
            return;
          }
          if (_logger.isInternal) {
            _logger.internal('Handler completed, sending response [id: $id]');
          }

          try {
            await _processor.send(response);
            await _processor.finishSending();
            if (_logger.isInternal) {
              _logger.internal('Response delivered to client [id: $id]');
            }
          } catch (e, stackTrace) {
            _logger.error(
              'Failed to send response to client [id: $id]',
              error: e,
              stackTrace: stackTrace,
            );
          } finally {
            _completeDone();
          }
        })
        .catchError((Object error, StackTrace stackTrace) async {
          if (RpcStatus.isFaultError(error)) {
            _logger.error(
              'Client stream handling failed [id: $id]',
              error: error,
              stackTrace: stackTrace,
            );
          }
          // Nothing awaits this chain, so a throw from the reply path would
          // reach the zone and take a server process with it.
          try {
            await sendWireError(error, _processor.sendError);
          } catch (e, st) {
            _logger.error(
              'Failed to report the handler failure to the peer [id: $id]',
              error: e,
              stackTrace: st,
            );
          } finally {
            _completeDone();
          }
        });
  }
}
