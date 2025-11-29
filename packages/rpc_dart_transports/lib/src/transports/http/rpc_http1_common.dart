// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

/// Заголовок, отвечающий за контроль целостности данных.
const String kRpcIntegrityHeader = 'x-rpc-integrity';

/// Заголовок, передающий Stream ID, сгенерированный вызывающей стороной.
const String kRpcStreamIdHeader = 'x-rpc-stream-id';

/// Контент-тип, используемый для передачи gRPC сообщений по HTTP/1.1.
const String kRpcGrpcContentType = 'application/grpc+proto';

/// Вычисляет SHA256 и возвращает результат в base64url-формате.
String computeRpcIntegrity(Uint8List data) {
  final digest = sha256.convert(data);
  return base64Url.encode(digest.bytes);
}

/// Проверяет, что буфер уже содержит gRPC фрейм.
bool isGrpcFrame(Uint8List data) {
  if (data.length < RpcConstants.messagePrefixSize) return false;

  try {
    final header = RpcMessageFrame.parseHeader(data);
    final expectedLength =
        header.messageLength + RpcConstants.messagePrefixSize;
    return expectedLength == data.length;
  } catch (_) {
    return false;
  }
}

/// Оборачивает данные в gRPC фрейм, если это ещё не сделано.
Uint8List ensureGrpcFrame(Uint8List data) {
  if (isGrpcFrame(data)) {
    return data;
  }

  return RpcMessageFrame.encode(data, compressed: false);
}

/// Преобразует RPC метаданные в заголовки HTTP/1.1 запроса.
void applyRpcMetadataToHttpRequest(
    HttpClientRequest request, RpcMetadata metadata) {
  for (final header in metadata.headers) {
    if (header.name.startsWith(':')) continue;
    request.headers.add(header.name, header.value);
  }
}

/// Преобразует HTTP/1.1 ответ в RPC метаданные.
RpcMetadata httpResponseToRpcMetadata(HttpClientResponse response) {
  final headers = <RpcHeader>[
    RpcHeader(':status', response.statusCode.toString())
  ];
  _appendHeaders(headers, response.headers, skipHeader: kRpcIntegrityHeader);
  return RpcMetadata(headers);
}

/// Преобразует HTTP/1.1 запрос в RPC метаданные.
RpcMetadata httpRequestToRpcMetadata(HttpRequest request) {
  final authority = request.headers.value(HttpHeaders.hostHeader) ??
      (request.uri.authority.isEmpty
          ? request.uri.path
          : request.uri.authority);

  final headers = <RpcHeader>[
    RpcHeader(':method', request.method),
    RpcHeader(':path', request.uri.path.isEmpty ? '/' : request.uri.path),
    RpcHeader(':scheme', request.uri.scheme),
    RpcHeader(':authority', authority),
  ];

  _appendHeaders(headers, request.headers, skipHeader: kRpcIntegrityHeader);
  return RpcMetadata(headers);
}

/// Применяет RPC метаданные к HTTP/1.1 ответу.
void applyRpcMetadataToHttpResponse(
    HttpResponse response, RpcMetadata metadata) {
  for (final header in metadata.headers) {
    if (header.name == ':status') {
      final parsed = int.tryParse(header.value);
      if (parsed != null) {
        response.statusCode = parsed;
      }
      continue;
    }

    if (header.name.startsWith(':')) continue;
    response.headers.add(header.name, header.value);
  }
}

void _appendHeaders(
  List<RpcHeader> accumulator,
  HttpHeaders headers, {
  String? skipHeader,
}) {
  headers.forEach((name, values) {
    if (skipHeader != null && name.toLowerCase() == skipHeader) {
      return;
    }

    for (final value in values) {
      accumulator.add(RpcHeader(name.toLowerCase(), value));
    }
  });
}
