// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Unary client: sends one request, gets one response (per call stream ID).
final class UnaryCaller<TRequest, TResponse> {
  /// Transport.
  final IRpcTransport _transport;

  /// Service name.
  final String _serviceName;

  /// Method name.
  final String _methodName;

  /// Method path `/Service/Method`.
  late final String _methodPath;

  /// Request codec.
  final IRpcCodec<TRequest> _requestSerializer;

  /// Response codec.
  final IRpcCodec<TResponse> _responseSerializer;

  /// RPC context.
  final RpcContext? _context;

  /// Logger.
  late final LogScope _logger;

  /// Creates a unary client.
  UnaryCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) : _transport = transport,
       _serviceName = serviceName,
       _methodName = methodName,
       _requestSerializer = requestCodec,
       _responseSerializer = responseCodec,
       _context = context {
    _logger = logger?.child('UnaryCaller') ?? LogScope.noop;
    _methodPath = '/$_serviceName/$_methodName';
    _logger.internal(
      'Created unary client for $_methodPath${_context != null ? ' with context' : ''}',
    );
  }

  /// Executes the unary call.
  Future<TResponse> call(TRequest request, {Duration? timeout}) async {
    // Check cancellation and deadline from context.
    _checkContextBeforeCall();

    // Determine timeout: parameter, context, or default.
    final remainingTime = _context?.remainingTime;
    final effectiveTimeout =
        timeout ?? remainingTime ?? const Duration(seconds: 60);

    // The call's own deadline, when that is what bounds the wait — an explicit
    // [timeout] argument takes precedence and is not a deadline. Used below to
    // report expiry as [RpcDeadlineExceededException] rather than a bare
    // [TimeoutException]: the other three call shapes all report a deadline
    // that way, and so does this method's own pre-flight check, so the type a
    // caller had to catch depended on whether the deadline passed just before
    // the call or just after it.
    final boundingDeadline = timeout == null ? _context?.deadline : null;

    // Create a new stream for this call.
    final streamId = _transport.createStream();

    _logger.internal('Unary call $_methodPath started [streamId: $streamId]');

    // Parser and peer encoding are per call, not per caller. RpcMessageParser
    // keeps a reassembly buffer, so a shared instance would carry the leftover
    // bytes of a truncated response — or of a concurrent call on the same
    // caller — into the next call's frame and decode garbage. This object is
    // reusable (call() takes no identity of its own), so the state that a call
    // mutates has to live inside call().
    String? peerGrpcEncoding;
    final parser = RpcMessageParser(
      logger: _logger,
      decompressor: (payload, {int? maxOutputBytes}) {
        final encoding = peerGrpcEncoding;
        if (encoding == null || encoding == RpcGrpcCompression.identity) {
          throw RpcStatusException(
            RpcStatus.internal,
            'Compressed gRPC payload received without grpc-encoding',
          );
        }
        return RpcGrpcCompression.decompress(
          payload,
          encoding: encoding,
          maxOutputBytes: maxOutputBytes,
        );
      },
    );

    final completer = Completer<TResponse>();
    StreamSubscription? subscription;
    StreamSubscription? cancellationSubscription;

    /// In-flight "the caller is gone" notice, awaited before the stream id is
    /// released so the frame goes out on a live id.
    Future<void>? cancellationNotice;

    try {
      // Subscribe to cancellation token if present.
      if (_context?.cancellationToken != null) {
        cancellationSubscription = _context!.cancellationToken!.cancelled
            .asStream()
            .listen((_) {
              if (!completer.isCompleted) {
                _logger.warning(
                  'Operation cancelled via cancellation token [streamId: $streamId]',
                );
                final reason =
                    _context.cancellationToken!.reason ??
                    'Operation was cancelled';
                // Tell the server. Unary used to cancel purely locally: the
                // future got RpcCancelledException, the subscription was
                // dropped, the stream id released — and nothing was ever sent,
                // so the handler ran to completion for a caller that was
                // already gone (measured: a 3s job cancelled after 100ms spent
                // 295 of its 300 work units post-cancellation). The streaming
                // callers already did this; unary, the most common shape, did
                // not, on every transport including HTTP/2.
                cancellationNotice = _notifyPeerOfCancellation(
                  _transport,
                  streamId,
                  reason,
                  _logger,
                );
                completer.completeError(RpcCancelledException(reason));
              }
            });
      }

      // Subscribe to responses for this stream.
      _logger.internal(
        'Configuring response subscription [streamId: $streamId]',
      );
      subscription = _transport
          .getMessagesForStream(streamId)
          .listen(
            (message) async {
              if (message.isDirect && message.directPayload != null) {
                // Zero-copy: received object directly.
                _logger.internal(
                  'Zero-copy response received [streamId: $streamId]',
                );
                try {
                  final response = message.directPayload as TResponse;
                  if (!completer.isCompleted) {
                    _logger.internal(
                      'Zero-copy unary call $_methodPath completed [streamId: $streamId]',
                    );
                    completer.complete(response);
                  } else {
                    _logger.warning(
                      'Extra zero-copy response after call completion [streamId: $streamId]',
                    );
                  }
                } catch (e, stackTrace) {
                  if (!completer.isCompleted) {
                    _logger.error(
                      'Failed to process zero-copy response [streamId: $streamId]',
                      error: e,
                      stackTrace: stackTrace,
                    );
                    completer.completeError(e);
                  }
                }
              } else if (!message.isMetadataOnly && message.payload != null) {
                // Received response data (serialized).
                if (_logger.isInternal) {
                  _logger.internal(
                    'Received transport message of ${message.payload!.length} bytes [streamId: $streamId]',
                  );
                }
                try {
                  // Use parser to extract messages from framed payload.
                  final messages = parser(message.payload!);
                  if (_logger.isInternal) {
                    _logger.internal(
                      'Parser extracted ${messages.length} messages from frame [streamId: $streamId]',
                    );
                  }

                  for (final msgBytes in messages) {
                    if (_logger.isInternal) {
                      _logger.internal(
                        'Deserializing response of ${msgBytes.length} bytes [streamId: $streamId]',
                      );
                    }
                    final response = _responseSerializer.deserialize(msgBytes);
                    if (!completer.isCompleted) {
                      _logger.internal(
                        'Unary call $_methodPath completed [streamId: $streamId]',
                      );
                      completer.complete(response);
                      break; // Only first response is needed for unary call.
                    } else {
                      _logger.warning(
                        'Extra response after call completion [streamId: $streamId]',
                      );
                    }
                  }
                } catch (e, stackTrace) {
                  if (!completer.isCompleted) {
                    _logger.error(
                      'Failed to process response [streamId: $streamId]',
                      error: e,
                      stackTrace: stackTrace,
                    );
                    completer.completeError(e);
                  }
                }
              } else if (message.isMetadataOnly && message.metadata != null) {
                // Received metadata (possibly trailers).
                _logger.internal('Metadata received [streamId: $streamId]');
                final encoding = message.metadata!.getHeaderValue(
                  RpcHeaders.grpcEncoding,
                );
                if (encoding != null) {
                  peerGrpcEncoding = encoding;
                }
                final statusCode = message.metadata!.getHeaderValue(
                  RpcHeaders.grpcStatus,
                );

                if (statusCode != null && message.isEndOfStream) {
                  final code = int.tryParse(statusCode) ?? RpcStatus.unknown;
                  _logger.internal(
                    'Completion status received: $code [streamId: $streamId]',
                  );
                  if (code != RpcStatus.ok && !completer.isCompleted) {
                    final errorMessage =
                        message.metadata!.getHeaderValue(
                          RpcHeaders.grpcMessage,
                        ) ??
                        '';
                    final decodedMessage = RpcMetadata.decodeGrpcMessage(
                      errorMessage,
                    );
                    _logger.error(
                      'gRPC error: $code - $decodedMessage [streamId: $streamId]',
                    );
                    completer.completeError(
                      RpcStatusException.fromTrailer(
                        code,
                        decodedMessage,
                        detailsBin: message.metadata!.statusDetailsBin,
                      ),
                    );
                  }
                }
              }
            },
            onError: (error, stackTrace) {
              _logger.error(
                'Transport error [streamId: $streamId]',
                error: error,
                stackTrace: stackTrace,
              );
              if (!completer.isCompleted) {
                completer.completeError(error);
              }
            },
          );

      // Send initial metadata with context headers.
      _logger.internal('Sending initial metadata [streamId: $streamId]');
      final baseMetadata = RpcMetadata.forClientRequest(
        _serviceName,
        _methodName,
      );

      // Use a map so context headers naturally override base headers,
      // preventing duplicates (e.g. grpc-accept-encoding).
      final headerMap = <String, String>{
        for (final h in baseMetadata.headers) h.name: h.value,
      };

      if (_context != null) {
        // User metadata must not clobber protocol-reserved headers.
        for (final entry in _context.headers.entries) {
          if (RpcHeaders.isReserved(entry.key)) continue;
          headerMap[entry.key] = entry.value;
        }

        if (_context.traceId != null) {
          headerMap[RpcHeaders.xTraceId] = _context.traceId!;
        }
        headerMap[RpcHeaders.xRequestId] = _context.requestId;

        if (_context.deadline != null) {
          final timeout = _context.remainingTime;
          if (timeout != null) {
            headerMap[RpcHeaders.grpcTimeout] = RpcMetadata.encodeGrpcTimeout(
              timeout,
            );
          }
        }

        _logger.internal(
          'Context headers added: ${_context.headers.length} custom + system',
        );
      }

      final metadata = RpcMetadata([
        for (final e in headerMap.entries) RpcHeader(e.key, e.value),
      ], methodPath: baseMetadata.methodPath);
      await _transport.sendMetadata(streamId, metadata);

      // Zero-copy optimization for supporting transports.
      if (_transport.supportsZeroCopy) {
        _logger.internal('Zero-copy request send [streamId: $streamId]');
        await _transport.sendDirectObject(
          streamId,
          request as Object,
          endStream: true,
        );
      } else {
        // Standard serialization for other transports.
        _logger.internal('Serializing request [streamId: $streamId]');
        final serializedRequest = _requestSerializer.serialize(request);
        final requestEncoding = _context?.getHeader(RpcHeaders.grpcEncoding);
        if (requestEncoding != null &&
            requestEncoding != RpcGrpcCompression.identity &&
            !RpcGrpcCompression.isSupported(requestEncoding)) {
          throw RpcException(
            'Unsupported grpc-encoding: $requestEncoding. '
            'Supported: ${RpcGrpcCompression.supportedEncodings().join(', ')}. '
            'On web/dart2js the built-in gzip is unavailable; register a '
            'cross-platform codec (e.g. RpcGzipCodec.register() from '
            'package:rpc_dart_compression).',
          );
        }
        final useCompression =
            requestEncoding != null &&
            requestEncoding != RpcGrpcCompression.identity;
        final payload = useCompression
            ? RpcGrpcCompression.compress(
                serializedRequest,
                encoding: requestEncoding,
              )
            : serializedRequest;
        _logger.internal(
          'Request serialized, size: ${serializedRequest.length} bytes [streamId: $streamId]',
        );
        final framedRequest = RpcMessageFrame.encode(
          payload,
          compressed: useCompression,
        );
        _logger.internal(
          'Sending request and closing request stream [streamId: $streamId]',
        );
        await _transport.sendMessage(streamId, framedRequest, endStream: true);
      }

      // Await response with timeout if provided.
      _logger.internal(
        'Response timeout set to $effectiveTimeout [streamId: $streamId]',
      );
      return await completer.future.timeout(
        effectiveTimeout,
        onTimeout: () {
          _logger.error(
            'Response timeout: $effectiveTimeout [streamId: $streamId]',
          );
          // A deadline that expires mid-call is the same event as one that had
          // already expired at _checkContextBeforeCall, so report it the same
          // way. An explicit `timeout:` argument is not a deadline and keeps
          // TimeoutException.
          if (boundingDeadline != null) {
            throw RpcDeadlineExceededException(
              boundingDeadline,
              effectiveTimeout,
            );
          }
          throw TimeoutException(
            'Call timeout: $effectiveTimeout',
            effectiveTimeout,
          );
        },
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Unary call $_methodPath failed [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      // Always cancel response stream subscription.
      _logger.internal(
        'Cancelling response subscription [streamId: $streamId]',
      );
      await subscription?.cancel();
      await cancellationSubscription?.cancel();
      // Let the cancellation notice finish before the id is released, so the
      // frame is not sent against an id the transport has already reclaimed.
      // _notifyPeerOfCancellation never throws.
      await cancellationNotice;
      // Release the transport stream id; the unary path never calls
      // finishSending(), so without this the id leaks against maxActiveStreams
      // and a long-lived client eventually fails with "Too many active streams".
      _transport.releaseStreamId(streamId);
    }
  }

  /// Closes the client; transport remains open.
  Future<void> close() async {
    // Client does not own the transport, so do not close it.
    _logger.internal('Unary client $_methodPath closed');
  }

  /// Validates context before call.
  void _checkContextBeforeCall() {
    if (_context == null) return;

    // Check cancellation.
    _context.cancellationToken?.throwIfCancelled();

    // Check deadline.
    if (_context.isExpired) {
      throw RpcDeadlineExceededException(_context.deadline!, Duration.zero);
    }

    _logger.internal(
      'Context verified: requestId=${_context.requestId}, traceId=${_context.traceId}',
    );
  }
}
