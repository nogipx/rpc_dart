// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'transport.dart';

/// [message] with a payload that owns its bytes.
///
/// A decoded payload is a view into the chunk it arrived in, and holding the
/// view holds the whole chunk -- while every buffer limit charges only the
/// payload. A peer packing a one-byte message with a megabyte on a stream
/// nobody reads pinned the megabyte per message. Used where a message WAITS;
/// one handed straight to a reading consumer keeps its view and costs no copy.
RpcTransportMessage ownedPayload(RpcTransportMessage message) {
  final payload = message.payload;
  if (payload == null ||
      payload.lengthInBytes == payload.buffer.lengthInBytes) {
    return message;
  }
  return RpcTransportMessage(
    payload: Uint8List.fromList(payload),
    directPayload: message.directPayload,
    metadata: message.metadata,
    isEndOfStream: message.isEndOfStream,
    methodPath: message.methodPath,
    streamId: message.streamId,
  );
}
