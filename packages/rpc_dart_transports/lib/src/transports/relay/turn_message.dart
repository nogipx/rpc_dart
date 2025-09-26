// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:universal_io/io.dart';

/// TURN/STUN message classes according to RFC 5389 / RFC 5766.
enum TurnMessageClass {
  request,
  indication,
  successResponse,
  errorResponse,
}

/// Utility representation of a TURN/STUN attribute.
final class TurnAttribute {
  TurnAttribute(this.type, Uint8List value)
      : value = Uint8List.fromList(value);

  final int type;
  final Uint8List value;

  int get paddedLength => (value.length + 3) & ~3;

  Uint8List toBytes() {
    final buffer = BytesBuilder();
    final header = ByteData(4);
    header.setUint16(0, type);
    header.setUint16(2, value.length);
    buffer.add(header.buffer.asUint8List());
    buffer.add(value);

    final padding = (4 - (value.length % 4)) % 4;
    if (padding > 0) {
      buffer.add(Uint8List(padding));
    }

    return buffer.toBytes();
  }
}

/// Representation of a TURN/STUN message with helper encode/decode utilities.
final class TurnMessage {
  TurnMessage({
    required this.method,
    required this.messageClass,
    Uint8List? transactionId,
    List<TurnAttribute>? attributes,
  })  : transactionId = transactionId ?? generateTransactionId(),
        attributes = List.unmodifiable(attributes ?? const []);

  /// TURN magic cookie value defined in RFC 5389 section 6.
  static const int magicCookie = 0x2112A442;

  /// TURN method number (12-bit value).
  final int method;

  /// TURN message class.
  final TurnMessageClass messageClass;

  /// Transaction identifier (12 bytes).
  final Uint8List transactionId;

  /// Message attributes.
  final List<TurnAttribute> attributes;

  /// Encodes the TURN message into raw bytes ready to send over UDP/TCP.
  Uint8List encode() {
    final builder = BytesBuilder();
    final header = ByteData(20);

    final messageType = _encodeMessageType(method, messageClass);
    header.setUint16(0, messageType);

    var totalLength = 0;
    for (final attribute in attributes) {
      totalLength += 4 + attribute.paddedLength;
    }
    header.setUint16(2, totalLength);
    header.setUint32(4, magicCookie);
    final txView = header.buffer.asUint8List(8, 12);
    txView.setAll(0, transactionId);

    builder.add(header.buffer.asUint8List());

    for (final attribute in attributes) {
      builder.add(attribute.toBytes());
    }

    return builder.toBytes();
  }

  /// Returns the value of the first attribute with the provided [type].
  Uint8List? firstAttribute(int type) {
    for (final attribute in attributes) {
      if (attribute.type == type) {
        return attribute.value;
      }
    }
    return null;
  }

  /// Returns all attribute values with the provided [type].
  Iterable<Uint8List> attributesOfType(int type) sync* {
    for (final attribute in attributes) {
      if (attribute.type == type) {
        yield attribute.value;
      }
    }
  }

  /// Decodes raw TURN/STUN bytes into a [TurnMessage] if possible.
  static TurnMessage? decode(Uint8List data) {
    if (data.length < 20) {
      return null;
    }

    // First two bits must be 00 for STUN/TURN messages.
    if ((data[0] & 0xC0) != 0) {
      return null;
    }

    final header = ByteData.sublistView(data, 0, 20);
    final messageType = header.getUint16(0);
    final length = header.getUint16(2);

    if (data.length < 20 + length) {
      return null;
    }

    final cookie = header.getUint32(4);
    if (cookie != magicCookie) {
      return null;
    }

    final transactionId = Uint8List.fromList(data.sublist(8, 20));

    final (method, messageClass) = _decodeMessageType(messageType);

    final attributes = <TurnAttribute>[];
    var offset = 20;
    while (offset + 4 <= 20 + length) {
      final attributeHeader = ByteData.sublistView(data, offset, offset + 4);
      final type = attributeHeader.getUint16(0);
      final attrLength = attributeHeader.getUint16(2);
      offset += 4;
      if (offset + attrLength > data.length) {
        return null;
      }
      final value = Uint8List.fromList(data.sublist(offset, offset + attrLength));
      offset += attrLength;

      // Skip padding to 4-byte boundary.
      final padding = (4 - (attrLength % 4)) % 4;
      offset += padding;

      attributes.add(TurnAttribute(type, value));
    }

    return TurnMessage(
      method: method,
      messageClass: messageClass,
      transactionId: transactionId,
      attributes: attributes,
    );
  }

  /// Builds a TURN success response using [request] transaction id.
  TurnMessage buildSuccessResponse(List<TurnAttribute> attributes) {
    return TurnMessage(
      method: method,
      messageClass: TurnMessageClass.successResponse,
      transactionId: transactionId,
      attributes: attributes,
    );
  }

  /// Builds a TURN error response for this request with [code] and [reason].
  TurnMessage buildErrorResponse({
    required int code,
    required String reason,
  }) {
    final buffer = BytesBuilder();
    final errorData = ByteData(4);
    errorData.setUint16(0, 0); // Reserved
    errorData.setUint8(2, code ~/ 100);
    errorData.setUint8(3, code % 100);
    buffer.add(errorData.buffer.asUint8List());
    buffer.add(Uint8List.fromList(reason.codeUnits));

    final attributes = [TurnAttribute(TurnAttributeType.errorCode, buffer.toBytes())];

    return TurnMessage(
      method: method,
      messageClass: TurnMessageClass.errorResponse,
      transactionId: transactionId,
      attributes: attributes,
    );
  }

  static int _encodeMessageType(int method, TurnMessageClass messageClass) {
    final classBits = switch (messageClass) {
      TurnMessageClass.request => 0,
      TurnMessageClass.indication => 1,
      TurnMessageClass.successResponse => 2,
      TurnMessageClass.errorResponse => 3,
    };

    var value = 0;
    value |= (method & 0xF80) << 2;
    value |= (method & 0x070) << 1;
    value |= (method & 0x00F);

    if ((classBits & 0x02) != 0) {
      value |= 0x0100;
    }
    if ((classBits & 0x01) != 0) {
      value |= 0x0010;
    }

    return value;
  }

  static (int, TurnMessageClass) _decodeMessageType(int messageType) {
    final method = ((messageType & 0x3E00) >> 2) |
        ((messageType & 0x00E0) >> 1) |
        (messageType & 0x000F);

    final classBits = ((messageType & 0x0100) >> 7) |
        ((messageType & 0x0010) >> 4);

    final messageClass = switch (classBits) {
      0 => TurnMessageClass.request,
      1 => TurnMessageClass.indication,
      2 => TurnMessageClass.successResponse,
      3 => TurnMessageClass.errorResponse,
      _ => TurnMessageClass.request,
    };

    return (method, messageClass);
  }

  static Uint8List generateTransactionId() {
    final randomBytes = Uint8List(12);
    for (var i = 0; i < randomBytes.length; i++) {
      randomBytes[i] = (DateTime.now().microsecondsSinceEpoch >> (i * 5)) & 0xFF;
    }
    return randomBytes;
  }
}

/// TURN attribute type constants used in this implementation.
abstract final class TurnAttributeType {
  static const int channelNumber = 0x000C;
  static const int lifetime = 0x000D;
  static const int xorPeerAddress = 0x0012;
  static const int data = 0x0013;
  static const int xorRelayedAddress = 0x0016;
  static const int requestedTransport = 0x0019;
  static const int xorMappedAddress = 0x0020;
  static const int errorCode = 0x0009;
  static const int software = 0x8022;
}

/// TURN method identifiers used by the relay server.
abstract final class TurnMethod {
  static const int allocate = 0x0003;
  static const int refresh = 0x0004;
  static const int send = 0x0006;
  static const int data = 0x0007;
  static const int createPermission = 0x0008;
  static const int channelBind = 0x0009;
  static const int connectRequest = 0x0400;
}

/// Encodes an IPv4 XOR'ed address attribute.
Uint8List encodeXorAddress(
  InternetAddress address,
  int port,
  Uint8List transactionId,
) {
  if (address.type != InternetAddressType.IPv4) {
    throw ArgumentError('Only IPv4 addresses are supported by this relay');
  }

  final data = ByteData(8);
  data.setUint8(1, 0x01); // Family IPv4
  data.setUint16(2, port ^ (TurnMessage.magicCookie >> 16));

  final cookieBytes = ByteData(4);
  cookieBytes.setUint32(0, TurnMessage.magicCookie);

  final raw = address.rawAddress;
  for (var i = 0; i < raw.length; i++) {
    data.setUint8(4 + i, raw[i] ^ cookieBytes.getUint8(i));
  }

  return data.buffer.asUint8List();
}

/// Decodes an IPv4 XOR'ed address attribute into an [InternetAddress] and port.
(InternetAddress address, int port) decodeXorAddress(
  Uint8List attributeValue,
  Uint8List _,
) {
  final data = ByteData.sublistView(attributeValue);
  final family = data.getUint8(1);
  if (family != 0x01) {
    throw UnsupportedError('Only IPv4 XOR addresses are supported');
  }

  final xPort = data.getUint16(2);
  final port = xPort ^ (TurnMessage.magicCookie >> 16);

  final cookieBytes = ByteData(4);
  cookieBytes.setUint32(0, TurnMessage.magicCookie);
  final addressBytes = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    addressBytes[i] = data.getUint8(4 + i) ^ cookieBytes.getUint8(i);
  }

  return (
    InternetAddress.fromRawAddress(
      addressBytes,
      type: InternetAddressType.IPv4,
    ),
    port,
  );
}

/// Encodes a lifetime attribute value (seconds as 32-bit integer).
Uint8List encodeLifetime(Duration lifetime) {
  final seconds = lifetime.inSeconds;
  final data = ByteData(4)..setUint32(0, seconds);
  return data.buffer.asUint8List();
}

/// Decodes lifetime attribute value.
Duration decodeLifetime(Uint8List value) {
  final data = ByteData.sublistView(value);
  final seconds = data.getUint32(0);
  return Duration(seconds: seconds);
}

/// Helper to encode a channel number attribute.
Uint8List encodeChannelNumber(int channelNumber) {
  final data = ByteData(4);
  data.setUint16(0, channelNumber);
  data.setUint16(2, 0);
  return data.buffer.asUint8List();
}

/// Decodes a channel number attribute.
int decodeChannelNumber(Uint8List value) {
  final data = ByteData.sublistView(value);
  return data.getUint16(0);
}

/// Encodes a DATA attribute payload.
Uint8List encodeData(Uint8List payload) => Uint8List.fromList(payload);

/// TURN requested transport protocol helper.
abstract final class TurnRequestedTransport {
  static const int tcp = 6;
  static const int udp = 17;
}

/// Decodes the REQUESTED-TRANSPORT attribute value into the IP protocol number.
int decodeRequestedTransport(Uint8List value) {
  if (value.isEmpty) {
    throw ArgumentError('REQUESTED-TRANSPORT attribute is empty');
  }
  return value[0];
}
