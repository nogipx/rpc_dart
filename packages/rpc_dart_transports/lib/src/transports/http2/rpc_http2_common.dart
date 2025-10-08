// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

/// gRPC Content-Type для HTTP/2
const String kGrpcContentType = 'application/grpc+proto';

/// gRPC User-Agent header
const String kGrpcUserAgent = 'rpc-dart/1.0.0';

// Используем RpcStatus из rpc_dart вместо дублирования

/// Конвертирует RPC метаданные в HTTP/2 headers
///
/// Использует стандартные метаданные из rpc_dart и дополняет их custom headers
List<http2.Header> rpcMetadataToHttp2Headers(
  RpcMetadata metadata, {
  String? method,
  String? path,
  String? scheme,
  String? authority,
}) {
  final headers = <http2.Header>[];

  // Конвертируем все RPC headers в HTTP/2 headers
  for (final rpcHeader in metadata.headers) {
    final headerName = rpcHeader.name.toLowerCase();

    // Перезаписываем scheme и authority если переданы явно
    if (headerName == ':scheme' && scheme != null) {
      headers.add(http2.Header.ascii(':scheme', scheme));
    } else if (headerName == ':authority' && authority != null) {
      headers.add(http2.Header.ascii(':authority', authority));
    } else {
      String headerValue;
      try {
        ascii.encode(rpcHeader.value);
        headerValue = rpcHeader.value;
      } on Object catch (_) {
        final encodedValue = base64UrlEncode(utf8.encode(rpcHeader.value));
        headerValue = encodedValue;
      }
      // Добавляем header как есть
      headers.add(http2.Header.ascii(headerName, headerValue));
    }
  }

  // Добавляем стандартные gRPC headers если их нет
  final hasUserAgent = metadata.headers.any(
    (h) => h.name.toLowerCase() == 'user-agent',
  );
  if (!hasUserAgent) {
    headers.add(http2.Header.ascii('user-agent', kGrpcUserAgent));
  }

  return headers;
}

/// Конвертирует HTTP/2 headers в RPC метаданные
///
/// Сохраняет все headers, включая системные HTTP/2 и gRPC headers
RpcMetadata http2HeadersToRpcMetadata(List<http2.Header> headers) {
  final rpcHeaders = <RpcHeader>[];

  for (final header in headers) {
    final name = String.fromCharCodes(header.name);
    var value = String.fromCharCodes(header.value);
    try {
      value = utf8.decode(base64Url.decode(value));
    } on Object {
      null;
    }

    // Сохраняем все headers как есть
    rpcHeaders.add(RpcHeader(name, value));
  }

  return RpcMetadata(rpcHeaders);
}

/// Гарантирует, что данные представляют собой корректно сформированный gRPC frame.
///
/// Если входные [data] уже содержат валидный 5-байтный префикс и длину,
/// возвращает исходный буфер без копирования. В противном случае добавляет
/// gRPC префикс, предполагая отсутствие сжатия.
Uint8List ensureGrpcFrame(Uint8List data) {
  if (data.length >= RpcConstants.messagePrefixSize) {
    try {
      final header = RpcMessageFrame.parseHeader(data);
      final expectedLength =
          RpcConstants.messagePrefixSize + header.messageLength;

      if (expectedLength == data.length) {
        return data;
      }
    } catch (_) {
      // Игнорируем ошибку и упаковываем данные заново.
    }
  }

  return RpcMessageFrame.encode(data, compressed: false);
}

/// Проверяет, что данные имеют валидный gRPC префикс и соответствующую длину.
bool isGrpcFrame(Uint8List data) {
  if (data.length < RpcConstants.messagePrefixSize) {
    return false;
  }

  try {
    final header = RpcMessageFrame.parseHeader(data);
    final expectedLength =
        RpcConstants.messagePrefixSize + header.messageLength;
    return expectedLength == data.length;
  } catch (_) {
    return false;
  }
}
