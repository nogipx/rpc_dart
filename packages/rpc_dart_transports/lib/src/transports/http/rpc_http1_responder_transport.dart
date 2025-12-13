// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import '../_base_transport.dart';
import 'rpc_http1_common.dart';

final class RpcHttp1ResponderTransport extends RpcTransportBase {
  final HttpRequest _request;
  final RpcLogger? _logger;
  final RpcSecurityPolicy _policy;
  final Completer<void> _requestCompletion = Completer<void>();
  bool _started = false;

  late final int _streamId;
  late final RpcMetadata _requestMetadata;
  final BytesBuilder _responsePayload = BytesBuilder(copy: false);
  RpcMetadata? _responseMetadata;
  bool _responseDispatched = false;

  RpcHttp1ResponderTransport({
    required HttpRequest request,
    RpcLogger? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  })  : _request = request,
        _logger = logger?.child('Http1ResponderTransport'),
        _policy = policy,
        super(isClient: false) {
    final headerValue = request.headers.value(kRpcStreamIdHeader);
    _streamId = headerValue != null
        ? int.tryParse(headerValue) ?? generateStreamId()
        : generateStreamId();
    _requestMetadata = httpRequestToRpcMetadata(_request, policy: _policy);
  }

  Future<void> get requestCompleted => _requestCompletion.future;

  void _listenToRequest() {
    unawaited(_collectRequestBody());
  }

  /// Запускает чтение HTTP/1.1 запроса.
  void start() {
    if (_started) return;
    _started = true;
    _listenToRequest();
  }

  Future<void> _collectRequestBody() async {
    var processed = false;
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in _request) {
        builder.add(chunk);
      }
      final payload = builder.takeBytes();
      final integrityHeader = _request.headers.value(kRpcIntegrityHeader);

      if (integrityHeader == null) {
        await _rejectRequest(
          'Missing integrity header',
          HttpStatus.badRequest,
        );
        return;
      }

      final computed = computeRpcIntegrity(payload);
      if (computed != integrityHeader) {
        await _rejectRequest(
          'Integrity checksum mismatch',
          HttpStatus.badRequest,
        );
        return;
      }

      final methodPath = _requestMetadata.methodPath ?? _request.uri.path;
      addIncomingMessage(
        RpcTransportMessage(
          streamId: _streamId,
          metadata: _requestMetadata,
          methodPath: methodPath,
        ),
      );
      processed = true;

      if (payload.isNotEmpty) {
        addIncomingMessage(
          RpcTransportMessage(
            streamId: _streamId,
            payload: Uint8List.fromList(payload),
          ),
        );
      }
    } catch (error, stackTrace) {
      _logger?.error(
        'Ошибка при чтении HTTP/1.1 запроса',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (processed) {
        addIncomingMessage(
          RpcTransportMessage(
            streamId: _streamId,
            isEndOfStream: true,
          ),
        );
      }
      if (!_requestCompletion.isCompleted) {
        _requestCompletion.complete();
      }
    }
  }

  Future<void> _rejectRequest(String message, int statusCode) async {
    try {
      final response = _request.response;
      response.statusCode = statusCode;
      response.headers.contentType = ContentType.text;
      response.write(message);
      await response.close();
    } finally {
      await close();
      if (!_requestCompletion.isCompleted) {
        _requestCompletion.complete();
      }
    }
  }

  @override
  int createStream() => _streamId;

  @override
  bool releaseStreamId(int streamId) {
    if (streamId != _streamId) return false;
    return super.releaseStreamId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    _ensureStream(streamId);

    final hasStatus = metadata.getHeaderValue(':status') != null;
    _responseMetadata = hasStatus
        ? metadata
        : RpcMetadata([
            ...RpcMetadata.forServerInitialResponse().headers,
            ...metadata.headers,
          ]);

    if (endStream) {
      await finishSending(streamId);
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    _ensureStream(streamId);
    _responsePayload.add(ensureGrpcFrame(data));

    if (endStream) {
      await finishSending(streamId);
    }
  }

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((message) => message.streamId == streamId);

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) {
    throw UnsupportedError(
      'HTTP/1.1 transport does not support zero-copy sendDirectObject',
    );
  }

  @override
  Future<void> finishSending(int streamId) async {
    _ensureStream(streamId);
    if (_responseDispatched) return;
    _responseDispatched = true;

    final metadata =
        _responseMetadata ?? RpcMetadata.forServerInitialResponse();
    final response = _request.response;
    applyRpcMetadataToHttpResponse(response, metadata, policy: _policy);
    response.headers.contentType ??= ContentType.parse(kRpcGrpcContentType);

    final bodyBytes = _responsePayload.takeBytes();
    response.headers.set(kRpcIntegrityHeader, computeRpcIntegrity(bodyBytes));
    response.headers.contentLength = bodyBytes.length;

    if (bodyBytes.isNotEmpty) {
      response.add(bodyBytes);
    }

    await response.close();
    await close();
  }

  void _ensureStream(int streamId) {
    if (_streamId != streamId) {
      throw StateError(
          'Stream $streamId не поддерживается HTTP/1.1 транспортом');
    }
  }

  @override
  Future<void> onClose() async {
    if (!_requestCompletion.isCompleted) {
      _requestCompletion.complete();
    }
  }
}
