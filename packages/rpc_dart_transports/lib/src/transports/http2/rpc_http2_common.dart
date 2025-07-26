// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
      // Добавляем header как есть
      headers.add(http2.Header.ascii(headerName, rpcHeader.value));
    }
  }

  // Добавляем стандартные gRPC headers если их нет
  final hasUserAgent =
      metadata.headers.any((h) => h.name.toLowerCase() == 'user-agent');
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
    final value = String.fromCharCodes(header.value);

    // Сохраняем все headers как есть
    rpcHeaders.add(RpcHeader(name, value));
  }

  return RpcMetadata(rpcHeaders);
}

/// Упаковывает данные в gRPC frame формат используя RpcMessageFrame
///
/// Делегирует упаковку стандартному классу из rpc_dart
Uint8List packGrpcMessage(Uint8List data) {
  return RpcMessageFrame.encode(data, compressed: false);
}
