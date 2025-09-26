// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';

/// Флаги RPC кадра поверх TURN канала.
class _RpcTurnFrameFlags {
  static const int endStream = 0x01;
  static const int metadata = 0x02;
}

/// Кодирует метаданные RPC в TURN кадр.
Uint8List encodeRpcTurnMetadataFrame(
  int streamId,
  RpcMetadata metadata, {
  bool endStream = false,
  String? methodPath,
}) {
  final frame = BytesBuilder();
  final header = ByteData(5);
  header.setUint32(0, streamId);

  var flags = _RpcTurnFrameFlags.metadata;
  if (endStream) {
    flags |= _RpcTurnFrameFlags.endStream;
  }
  header.setUint8(4, flags);
  frame.add(header.buffer.asUint8List());

  final jsonMap = <String, Object?>{
    'headers': metadata.headers
        .map((header) => {'name': header.name, 'value': header.value})
        .toList(),
  };

  if (methodPath != null) {
    jsonMap['methodPath'] = methodPath;
  }

  frame.add(utf8.encode(json.encode(jsonMap)));

  return frame.toBytes();
}

/// Кодирует gRPC payload в TURN кадр.
Uint8List encodeRpcTurnDataFrame(
  int streamId,
  Uint8List payload, {
  bool endStream = false,
}) {
  final frame = BytesBuilder();
  final header = ByteData(5);
  header.setUint32(0, streamId);
  header.setUint8(
    4,
    endStream ? _RpcTurnFrameFlags.endStream : 0,
  );

  frame.add(header.buffer.asUint8List());
  frame.add(payload);

  return frame.toBytes();
}

/// Декодирует кадр TURN в [RpcTransportMessage].
/// Возвращает null, если кадр поврежден.
RpcTransportMessage? decodeRpcTurnFrame(
  Uint8List frame,
  Map<int, RpcMessageParser> streamParsers,
) {
  if (frame.length < 5) {
    return null;
  }

  final header = ByteData.sublistView(frame, 0, 5);
  final streamId = header.getUint32(0);
  final flags = header.getUint8(4);
  final payload = frame.sublist(5);

  final isEndStream = (flags & _RpcTurnFrameFlags.endStream) != 0;
  final isMetadata = (flags & _RpcTurnFrameFlags.metadata) != 0;

  if (isMetadata) {
    try {
      final jsonMap = json.decode(utf8.decode(payload));
      if (jsonMap is! Map<String, dynamic>) {
        return null;
      }

      final headers = <RpcHeader>[];
      final rawHeaders = jsonMap['headers'];
      if (rawHeaders is List) {
        for (final entry in rawHeaders) {
          if (entry is Map<String, dynamic>) {
            final name = entry['name'];
            final value = entry['value'];
            if (name is String && value is String) {
              headers.add(RpcHeader(name, value));
            }
          }
        }
      }

      final metadata = RpcMetadata(headers);
      final methodPath = jsonMap['methodPath'] as String?;

      return RpcTransportMessage(
        streamId: streamId,
        metadata: metadata,
        isEndOfStream: isEndStream,
        methodPath: methodPath,
      );
    } catch (_) {
      return null;
    }
  }

  // Декодирование gRPC payload с помощью RpcMessageParser.
  final parser = streamParsers.putIfAbsent(
    streamId,
    () => RpcMessageParser(),
  );

  final messages = parser(payload);
  if (messages.isEmpty) {
    return null;
  }

  final data = messages.last;
  if (isEndStream) {
    streamParsers.remove(streamId);
  }

  return RpcTransportMessage(
    streamId: streamId,
    payload: data,
    isEndOfStream: isEndStream,
  );
}

/// Помогает разослать сразу несколько сообщений из одного кадра (в случае
/// фрагментации gRPC payload).
Iterable<RpcTransportMessage> decodeRpcTurnFrameToMessages(
  Uint8List frame,
  Map<int, RpcMessageParser> streamParsers,
) sync* {
  if (frame.length < 5) {
    return;
  }

  final header = ByteData.sublistView(frame, 0, 5);
  final streamId = header.getUint32(0);
  final flags = header.getUint8(4);
  final payload = frame.sublist(5);

  final isEndStream = (flags & _RpcTurnFrameFlags.endStream) != 0;
  final isMetadata = (flags & _RpcTurnFrameFlags.metadata) != 0;

  if (isMetadata) {
    final message = decodeRpcTurnFrame(frame, streamParsers);
    if (message != null) {
      yield message;
    }
    return;
  }

  final parser = streamParsers.putIfAbsent(
    streamId,
    () => RpcMessageParser(),
  );

  final messages = parser(payload);
  for (var i = 0; i < messages.length; i++) {
    final data = messages[i];
    final isLast = i == messages.length - 1;
    yield RpcTransportMessage(
      streamId: streamId,
      payload: data,
      isEndOfStream: isEndStream && isLast,
    );
  }

  if (isEndStream) {
    streamParsers.remove(streamId);
  }
}

/// Управляет освобождением StreamId после получения финальных кадров.
void releaseStreamIdIfNeeded(
  RpcTransportMessage message,
  RpcStreamIdManager idManager,
  Map<int, RpcMessageParser> parsers,
) {
  if (!message.isEndOfStream) {
    return;
  }

  parsers.remove(message.streamId);
  idManager.releaseId(message.streamId);
}

