// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'turn_message.dart';

/// Decodes TURN/STUN and ChannelData frames transported over TCP streams.
final class TurnTcpFrameDecoder {
  TurnTcpFrameDecoder({
    required this.onTurnMessage,
    required this.onChannelData,
  });

  final void Function(TurnMessage message) onTurnMessage;
  final void Function(int channelNumber, Uint8List payload) onChannelData;

  Uint8List _buffer = Uint8List(0);

  /// Feeds raw TCP chunks into the decoder.
  void addChunk(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }

    if (_buffer.isEmpty) {
      _buffer = Uint8List.fromList(chunk);
    } else {
      final merged = Uint8List(_buffer.length + chunk.length);
      merged.setRange(0, _buffer.length, _buffer);
      merged.setRange(_buffer.length, merged.length, chunk);
      _buffer = merged;
    }

    _drainBuffer();
  }

  void _drainBuffer() {
    var offset = 0;

    while (offset < _buffer.length) {
      final remaining = _buffer.length - offset;
      if (remaining < 4) {
        break;
      }

      final firstByte = _buffer[offset];

      // ChannelData packets start with 0b01 (RFC 5766 section 10).
      if ((firstByte & 0xC0) == 0x40) {
        if (remaining < 4) {
          break;
        }

        final header = ByteData.sublistView(_buffer, offset, offset + 4);
        final channelNumber = header.getUint16(0);
        final length = header.getUint16(2);
        final paddedLength = (length + 3) & ~3;
        final totalLength = 4 + paddedLength;

        if (remaining < totalLength) {
          break;
        }

        final payload = Uint8List.fromList(
          _buffer.sublist(offset + 4, offset + 4 + length),
        );
        onChannelData(channelNumber, payload);
        offset += totalLength;
        continue;
      }

      // STUN/TURN messages begin with 0b00 (RFC 5389 section 6).
      if ((firstByte & 0xC0) == 0x00) {
        if (remaining < 20) {
          break;
        }

        final header = ByteData.sublistView(_buffer, offset, offset + 20);
        final length = header.getUint16(2);
        final totalLength = 20 + length;
        if (remaining < totalLength) {
          break;
        }

        final messageBytes = Uint8List.fromList(
          _buffer.sublist(offset, offset + totalLength),
        );
        final message = TurnMessage.decode(messageBytes);
        if (message != null) {
          onTurnMessage(message);
        }
        offset += totalLength;
        continue;
      }

      // Unknown framing; drop one byte to resynchronise.
      offset += 1;
    }

    if (offset == 0) {
      return;
    }

    if (offset >= _buffer.length) {
      _buffer = Uint8List(0);
    } else {
      _buffer = Uint8List.fromList(_buffer.sublist(offset));
    }
  }
}

/// Encodes a TURN ChannelData frame suitable for TCP transport.
Uint8List encodeChannelDataFrame(int channelNumber, Uint8List payload) {
  final length = payload.length;
  final paddedLength = (length + 3) & ~3;
  final buffer = Uint8List(4 + paddedLength);
  final header = ByteData.sublistView(buffer, 0, 4);
  header.setUint16(0, channelNumber);
  header.setUint16(2, length);
  buffer.setRange(4, 4 + length, payload);
  return buffer;
}
