// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'rpc_http1_common.dart';

final class RpcHttp1CallerTransport extends RpcBaseTransport {
  final Uri _baseUri;
  final HttpClient _httpClient;
  final RpcLogger? _logger;

  final Map<int, _Http1StreamContext> _pendingStreams = {};

  RpcHttp1CallerTransport._({
    required Uri baseUri,
    required HttpClient httpClient,
    RpcLogger? logger,
  })  : _baseUri = baseUri,
        _httpClient = httpClient,
        _logger = logger?.child('Http1CallerTransport'),
        super(isClient: true, logger: logger?.child('Http1CallerTransport'));

  factory RpcHttp1CallerTransport.connect(
    Uri baseUri, {
    RpcLogger? logger,
    HttpClient? httpClient,
  }) {
    return RpcHttp1CallerTransport._(
      baseUri: baseUri,
      httpClient: httpClient ?? HttpClient(),
      logger: logger,
    );
  }

  @override
  int createStream() {
    final streamId = generateStreamId();
    _pendingStreams[streamId] = _Http1StreamContext();
    _logger?.debug('Создан unary stream: $streamId');
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    _pendingStreams.remove(streamId);
    return super.releaseStreamId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (isClosed) throw StateError('Transport is closed');
    final context = _pendingStreams[streamId];
    if (context == null) {
      throw StateError('Stream $streamId not found (metadata).');
    }

    context.metadata = metadata;
    context.methodPath = metadata.methodPath;

    _logger?.debug(
      'Метаданные для stream $streamId сохранены (endStream: $endStream)',
    );

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
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (isClosed) throw StateError('Transport is closed');
    final context = _pendingStreams[streamId];
    if (context == null) {
      throw StateError('Stream $streamId not found (message).');
    }

    final framed = ensureGrpcFrame(data);
    context.payload.add(framed);

    _logger?.debug(
      'Сохранены ${framed.length} байт для stream $streamId (endStream: $endStream)',
    );

    if (endStream) {
      await finishSending(streamId);
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    final context = _pendingStreams.remove(streamId);
    if (context == null) return;

    final metadata = context.metadata;
    final methodPath = context.methodPath;

    if (metadata == null || methodPath == null) {
      throw StateError('Метаданные обязательны для stream $streamId');
    }

    _logger?.info(
        'Отправка unary HTTP/1.1 запроса для stream $streamId ($methodPath)');

    final uri = _buildMethodUri(methodPath);
    final bodyBytes = context.payload.takeBytes();

    try {
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.parse(kRpcGrpcContentType);
      request.headers.contentLength = bodyBytes.length;
      request.headers.set(kRpcStreamIdHeader, streamId.toString());
      applyRpcMetadataToHttpRequest(request, metadata);
      request.headers.set(kRpcIntegrityHeader, computeRpcIntegrity(bodyBytes));

      if (bodyBytes.isNotEmpty) {
        request.add(bodyBytes);
      }

      final response = await request.close();
      await _processResponse(response, streamId, methodPath);
    } catch (error, stackTrace) {
      _logger?.error(
        'Ошибка HTTP/1.1 запроса для stream $streamId: $error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Uri _buildMethodUri(String methodPath) {
    final normalized = methodPath.startsWith('/') ? methodPath : '/$methodPath';
    return _baseUri.replace(path: normalized);
  }

  Future<void> _processResponse(
    HttpClientResponse response,
    int streamId,
    String methodPath,
  ) async {
    if (response.statusCode >= 400) {
      throw RpcException(
          'HTTP ${response.statusCode} ${response.reasonPhrase}');
    }

    final integrityHeader = response.headers.value(kRpcIntegrityHeader);
    if (integrityHeader == null) {
      throw RpcException('Missing integrity header in HTTP response');
    }

    final body = await _collectResponseData(response);
    final computed = computeRpcIntegrity(body);
    if (computed != integrityHeader) {
      throw RpcException('Integrity mismatch on stream $streamId');
    }

    final metadata = httpResponseToRpcMetadata(response);
    final metadataMessage = RpcTransportMessage(
      streamId: streamId,
      metadata: metadata,
      methodPath: methodPath,
      isEndOfStream: body.isEmpty,
    );
    addIncomingMessage(metadataMessage);

    if (body.isNotEmpty) {
      addIncomingMessage(
        RpcTransportMessage(
          streamId: streamId,
          payload: Uint8List.fromList(body),
          isEndOfStream: true,
        ),
      );
    }
  }

  Future<Uint8List> _collectResponseData(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> onClose() async {
    _httpClient.close(force: true);
  }
}

final class _Http1StreamContext {
  final BytesBuilder payload = BytesBuilder(copy: false);
  RpcMetadata? metadata;
  String? methodPath;
}
