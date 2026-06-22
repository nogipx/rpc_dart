// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

/// A structured error detail attached to [RpcStatusException].
///
/// Mirrors `google.protobuf.Any` — each detail has a [typeUrl] and binary
/// payload. Common detail types provide typed Dart APIs on top.
abstract class RpcErrorDetail {
  /// Protobuf type URL identifying the detail type.
  String get typeUrl;

  /// Encodes the detail payload (without the Any wrapper).
  Uint8List encode();

  /// Encodes as a protobuf `google.protobuf.Any` message.
  Uint8List encodeAsAny() {
    final typeUrlBytes = utf8.encode(typeUrl);
    final valueBytes = encode();
    final buf = BytesBuilder(copy: false);
    // field 1 (type_url): tag=0x0A, length-delimited
    buf.addByte(0x0A);
    _writeVarint(buf, typeUrlBytes.length);
    buf.add(typeUrlBytes);
    // field 2 (value): tag=0x12, length-delimited
    if (valueBytes.isNotEmpty) {
      buf.addByte(0x12);
      _writeVarint(buf, valueBytes.length);
      buf.add(valueBytes);
    }
    return buf.toBytes();
  }

  /// Decodes an Any message into a typed [RpcErrorDetail].
  /// Returns [RpcRawErrorDetail] for unknown types.
  static RpcErrorDetail decodeAny(Uint8List data) {
    String? typeUrl;
    Uint8List? value;

    var offset = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;

      if (wireType == 2) {
        // length-delimited
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final bytes = _readLengthDelimited(data, offset, len);
        offset += len;
        if (fieldNumber == 1) typeUrl = utf8.decode(bytes);
        if (fieldNumber == 2) value = bytes;
      } else if (wireType == 0) {
        // varint — skip
        final (_, newOffset) = _readVarint(data, offset);
        offset = newOffset;
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }

    typeUrl ??= '';
    value ??= Uint8List(0);

    switch (typeUrl) {
      case RpcBadRequest.type:
        return RpcBadRequest._decode(value);
      case RpcRetryInfo.type:
        return RpcRetryInfo._decode(value);
      case RpcDebugInfo.type:
        return RpcDebugInfo._decode(value);
      case RpcErrorInfo.type:
        return RpcErrorInfo._decode(value);
      default:
        return RpcRawErrorDetail(typeUrl: typeUrl, value: value);
    }
  }
}

/// Encodes a `google.rpc.Status` message (used for `grpc-status-details-bin`).
Uint8List encodeRpcStatus(
  int code,
  String message,
  List<RpcErrorDetail> details,
) {
  final buf = BytesBuilder(copy: false);
  // field 1 (code): tag=0x08, varint
  if (code != 0) {
    buf.addByte(0x08);
    _writeVarint(buf, code);
  }
  // field 2 (message): tag=0x12, length-delimited
  if (message.isNotEmpty) {
    final msgBytes = utf8.encode(message);
    buf.addByte(0x12);
    _writeVarint(buf, msgBytes.length);
    buf.add(msgBytes);
  }
  // field 3 (details): tag=0x1A, length-delimited (repeated Any)
  for (final detail in details) {
    final anyBytes = detail.encodeAsAny();
    buf.addByte(0x1A);
    _writeVarint(buf, anyBytes.length);
    buf.add(anyBytes);
  }
  return buf.toBytes();
}

/// Decodes a `google.rpc.Status` message from `grpc-status-details-bin`.
/// Returns (code, message, details).
({int code, String message, List<RpcErrorDetail> details}) decodeRpcStatus(
  Uint8List data,
) {
  int code = 0;
  String message = '';
  final details = <RpcErrorDetail>[];

  var offset = 0;
  while (offset < data.length) {
    if (offset >= data.length) break;
    final tag = data[offset++];
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x07;

    if (wireType == 0) {
      final (value, newOffset) = _readVarint(data, offset);
      offset = newOffset;
      if (fieldNumber == 1) code = value;
    } else if (wireType == 2) {
      final (len, newOffset) = _readVarint(data, offset);
      offset = newOffset;
      final bytes = _readLengthDelimited(data, offset, len);
      offset += len;
      if (fieldNumber == 2) {
        message = utf8.decode(bytes);
      } else if (fieldNumber == 3) {
        details.add(RpcErrorDetail.decodeAny(bytes));
      }
    } else {
      offset = _skipField(data, offset, wireType);
    }
  }

  return (code: code, message: message, details: details);
}

// -- Common detail types --

/// Describes field-level validation errors.
class RpcBadRequest extends RpcErrorDetail {
  /// Protobuf type URL for BadRequest.
  static const type = 'type.googleapis.com/google.rpc.BadRequest';

  /// Field-level violations that caused the error.
  final List<RpcFieldViolation> violations;

  /// Creates a [RpcBadRequest] with the given [violations].
  RpcBadRequest(this.violations);

  @override
  String get typeUrl => type;

  @override
  Uint8List encode() {
    final buf = BytesBuilder(copy: false);
    for (final v in violations) {
      final inner = BytesBuilder(copy: false);
      // field 1 (field): string
      if (v.field.isNotEmpty) {
        final fieldBytes = utf8.encode(v.field);
        inner.addByte(0x0A);
        _writeVarint(inner, fieldBytes.length);
        inner.add(fieldBytes);
      }
      // field 2 (description): string
      if (v.description.isNotEmpty) {
        final descBytes = utf8.encode(v.description);
        inner.addByte(0x12);
        _writeVarint(inner, descBytes.length);
        inner.add(descBytes);
      }
      // wrap as field 1 of BadRequest (repeated FieldViolation)
      final innerBytes = inner.toBytes();
      buf.addByte(0x0A);
      _writeVarint(buf, innerBytes.length);
      buf.add(innerBytes);
    }
    return buf.toBytes();
  }

  static RpcBadRequest _decode(Uint8List data) {
    final violations = <RpcFieldViolation>[];
    var offset = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final wireType = tag & 0x07;
      if (wireType == 2) {
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final bytes = _readLengthDelimited(data, offset, len);
        offset += len;
        violations.add(_decodeFieldViolation(bytes));
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }
    return RpcBadRequest(violations);
  }

  static RpcFieldViolation _decodeFieldViolation(Uint8List data) {
    String field = '';
    String description = '';
    var offset = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      if (wireType == 2) {
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final bytes = _readLengthDelimited(data, offset, len);
        offset += len;
        if (fieldNumber == 1) field = utf8.decode(bytes);
        if (fieldNumber == 2) description = utf8.decode(bytes);
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }
    return RpcFieldViolation(field: field, description: description);
  }

  @override
  String toString() => 'RpcBadRequest($violations)';
}

/// A single field validation error.
class RpcFieldViolation {
  /// Field path that caused the violation (e.g. "user.email").
  final String field;

  /// Human-readable description of the violation.
  final String description;

  /// Creates a field violation.
  const RpcFieldViolation({required this.field, required this.description});

  @override
  String toString() => '$field: $description';
}

/// Tells the client how long to wait before retrying.
class RpcRetryInfo extends RpcErrorDetail {
  /// Protobuf type URL for RetryInfo.
  static const type = 'type.googleapis.com/google.rpc.RetryInfo';

  /// How long the client should wait before retrying.
  final Duration retryDelay;

  /// Creates a [RpcRetryInfo] with the given [retryDelay].
  RpcRetryInfo(this.retryDelay);

  @override
  String get typeUrl => type;

  @override
  Uint8List encode() {
    // google.protobuf.Duration: field 1 = seconds (int64), field 2 = nanos (int32)
    final buf = BytesBuilder(copy: false);
    // field 1 of RetryInfo is google.protobuf.Duration (retry_delay)
    final durationBuf = BytesBuilder(copy: false);
    final seconds = retryDelay.inSeconds;
    final nanos = (retryDelay.inMicroseconds - seconds * 1000000) * 1000;
    if (seconds != 0) {
      durationBuf.addByte(0x08);
      _writeVarint(durationBuf, seconds);
    }
    if (nanos != 0) {
      durationBuf.addByte(0x10);
      _writeVarint(durationBuf, nanos);
    }
    final durationBytes = durationBuf.toBytes();
    buf.addByte(0x0A);
    _writeVarint(buf, durationBytes.length);
    buf.add(durationBytes);
    return buf.toBytes();
  }

  static RpcRetryInfo _decode(Uint8List data) {
    // field 1 is Duration message
    var offset = 0;
    int seconds = 0;
    int nanos = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      if (wireType == 2 && fieldNumber == 1) {
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final durationBytes = _readLengthDelimited(data, offset, len);
        offset += len;
        // parse Duration
        var dOffset = 0;
        while (dOffset < durationBytes.length) {
          final dTag = durationBytes[dOffset++];
          final dField = dTag >> 3;
          final (val, dNewOffset) = _readVarint(durationBytes, dOffset);
          dOffset = dNewOffset;
          if (dField == 1) seconds = val;
          if (dField == 2) nanos = val;
        }
      } else if (wireType == 0) {
        final (_, newOffset) = _readVarint(data, offset);
        offset = newOffset;
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }
    return RpcRetryInfo(
      Duration(seconds: seconds, microseconds: nanos ~/ 1000),
    );
  }

  @override
  String toString() => 'RpcRetryInfo(${retryDelay.inMilliseconds}ms)';
}

/// Server-side debug information (stack traces, diagnostic details).
class RpcDebugInfo extends RpcErrorDetail {
  /// Protobuf type URL for DebugInfo.
  static const type = 'type.googleapis.com/google.rpc.DebugInfo';

  /// Stack trace entries from the server.
  final List<String> stackEntries;

  /// Additional diagnostic detail string.
  final String detail;

  /// Creates a [RpcDebugInfo] with optional [stackEntries] and [detail].
  RpcDebugInfo({this.stackEntries = const [], this.detail = ''});

  @override
  String get typeUrl => type;

  @override
  Uint8List encode() {
    final buf = BytesBuilder(copy: false);
    // field 1 (stack_entries): repeated string
    for (final entry in stackEntries) {
      final entryBytes = utf8.encode(entry);
      buf.addByte(0x0A);
      _writeVarint(buf, entryBytes.length);
      buf.add(entryBytes);
    }
    // field 2 (detail): string
    if (detail.isNotEmpty) {
      final detailBytes = utf8.encode(detail);
      buf.addByte(0x12);
      _writeVarint(buf, detailBytes.length);
      buf.add(detailBytes);
    }
    return buf.toBytes();
  }

  static RpcDebugInfo _decode(Uint8List data) {
    final entries = <String>[];
    String detail = '';
    var offset = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      if (wireType == 2) {
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final bytes = _readLengthDelimited(data, offset, len);
        offset += len;
        if (fieldNumber == 1) entries.add(utf8.decode(bytes));
        if (fieldNumber == 2) detail = utf8.decode(bytes);
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }
    return RpcDebugInfo(stackEntries: entries, detail: detail);
  }

  @override
  String toString() => 'RpcDebugInfo($detail)';
}

/// Describes the cause of an error with a reason, domain, and metadata.
class RpcErrorInfo extends RpcErrorDetail {
  /// Protobuf type URL for ErrorInfo.
  static const type = 'type.googleapis.com/google.rpc.ErrorInfo';

  /// Machine-readable error reason (e.g. "QUOTA_EXCEEDED").
  final String reason;

  /// Logical domain grouping (e.g. "billing.v1").
  final String domain;

  /// Additional key-value metadata about the error.
  final Map<String, String> metadata;

  /// Creates an [RpcErrorInfo] with the given [reason], [domain], and [metadata].
  RpcErrorInfo({
    required this.reason,
    this.domain = '',
    this.metadata = const {},
  });

  @override
  String get typeUrl => type;

  @override
  Uint8List encode() {
    final buf = BytesBuilder(copy: false);
    // field 1 (reason): string
    if (reason.isNotEmpty) {
      final reasonBytes = utf8.encode(reason);
      buf.addByte(0x0A);
      _writeVarint(buf, reasonBytes.length);
      buf.add(reasonBytes);
    }
    // field 2 (domain): string
    if (domain.isNotEmpty) {
      final domainBytes = utf8.encode(domain);
      buf.addByte(0x12);
      _writeVarint(buf, domainBytes.length);
      buf.add(domainBytes);
    }
    // field 3 (metadata): map<string, string>
    // Proto map encoding: repeated message { string key = 1; string value = 2; }
    for (final entry in metadata.entries) {
      final mapEntry = BytesBuilder(copy: false);
      final keyBytes = utf8.encode(entry.key);
      mapEntry.addByte(0x0A);
      _writeVarint(mapEntry, keyBytes.length);
      mapEntry.add(keyBytes);
      final valBytes = utf8.encode(entry.value);
      mapEntry.addByte(0x12);
      _writeVarint(mapEntry, valBytes.length);
      mapEntry.add(valBytes);
      final mapEntryBytes = mapEntry.toBytes();
      buf.addByte(0x1A);
      _writeVarint(buf, mapEntryBytes.length);
      buf.add(mapEntryBytes);
    }
    return buf.toBytes();
  }

  static RpcErrorInfo _decode(Uint8List data) {
    String reason = '';
    String domain = '';
    final metadata = <String, String>{};
    var offset = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      if (wireType == 2) {
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final bytes = _readLengthDelimited(data, offset, len);
        offset += len;
        if (fieldNumber == 1) reason = utf8.decode(bytes);
        if (fieldNumber == 2) domain = utf8.decode(bytes);
        if (fieldNumber == 3) {
          // decode map entry
          final (key, value) = _decodeMapEntry(bytes);
          if (key != null) metadata[key] = value ?? '';
        }
      } else if (wireType == 0) {
        final (_, newOffset) = _readVarint(data, offset);
        offset = newOffset;
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }
    return RpcErrorInfo(reason: reason, domain: domain, metadata: metadata);
  }

  static (String?, String?) _decodeMapEntry(Uint8List data) {
    String? key;
    String? value;
    var offset = 0;
    while (offset < data.length) {
      final tag = data[offset++];
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;
      if (wireType == 2) {
        final (len, newOffset) = _readVarint(data, offset);
        offset = newOffset;
        final bytes = _readLengthDelimited(data, offset, len);
        offset += len;
        if (fieldNumber == 1) key = utf8.decode(bytes);
        if (fieldNumber == 2) value = utf8.decode(bytes);
      } else {
        offset = _skipField(data, offset, wireType);
      }
    }
    return (key, value);
  }

  @override
  String toString() => 'RpcErrorInfo($reason, $domain)';
}

/// An unknown/unrecognized error detail preserved as raw bytes.
class RpcRawErrorDetail extends RpcErrorDetail {
  @override
  final String typeUrl;

  /// Raw protobuf-encoded value bytes.
  final Uint8List value;

  /// Creates a raw error detail preserving unknown type data.
  RpcRawErrorDetail({required this.typeUrl, required this.value});

  @override
  Uint8List encode() => value;

  @override
  String toString() => 'RpcRawErrorDetail($typeUrl, ${value.length} bytes)';
}

// -- Protobuf varint helpers --

/// Encodes a signed integer as a protobuf base-128 varint.
///
/// Per the protobuf spec, signed `int32`/`int64` fields encode negative values
/// as their unsigned 64-bit two's-complement representation, which always
/// occupies the full 10 bytes. Both reachable numeric fields here are signed:
/// the gRPC status `code` (int32) and the `RetryInfo` Duration `seconds`
/// (int64). A negative [Duration] yields a negative `seconds`, and a long
/// retry delay can push `seconds` above 2^32.
///
/// dart2js-safe: it never relies on `>>`/`<<` past 32 bits (undefined in
/// JavaScript, where ints are doubles). Non-negative values are peeled with
/// integer division (`~/ 0x80`); negatives are streamed from their two's
/// complement split into 32-bit hi/lo halves, mirroring the uint64 technique in
/// `special_cbor.dart` (`value ~/ 0x100000000`).
void _writeVarint(BytesBuilder buf, int value) {
  if (value >= 0) {
    var v = value;
    while (v >= 0x80) {
      buf.addByte((v & 0x7F) | 0x80);
      v = v ~/ 0x80;
    }
    buf.addByte(v & 0x7F);
    return;
  }
  // Build the unsigned 64-bit two's complement as 32-bit hi/lo halves.
  final magnitude = -value;
  final magLo = magnitude & 0xFFFFFFFF;
  final magHi = (magnitude ~/ 0x100000000) & 0xFFFFFFFF;
  final invLo = (~magLo) & 0xFFFFFFFF;
  final invHi = (~magHi) & 0xFFFFFFFF;
  var lo = (invLo + 1) & 0xFFFFFFFF;
  final carry = (invLo + 1) > 0xFFFFFFFF ? 1 : 0;
  var hi = (invHi + carry) & 0xFFFFFFFF;
  // Stream the first 9 of 10 groups, shifting the 64-bit value right by 7 each
  // step using division on each half (carry the low 7 bits of hi into lo).
  for (var i = 0; i < 9; i++) {
    buf.addByte((lo & 0x7F) | 0x80);
    final carryBits = (hi & 0x7F) * 0x2000000; // hi[0..6] -> lo[25..31]
    lo = ((lo ~/ 0x80) + carryBits) & 0xFFFFFFFF;
    hi = hi ~/ 0x80;
  }
  buf.addByte(lo & 0x7F);
}

/// Advances [offset] past one field of the given [wireType] without decoding
/// it, returning the new offset.
///
/// Protobuf's forward-compatibility rule requires unknown fields to be SKIPPED
/// rather than treated as fatal: a peer (or a future revision of the message)
/// may add a field of any wire type before one we care about, and aborting on
/// it would silently drop every field that follows. Throws [FormatException]
/// for the deprecated group wire types (3/4), which this decoder does not
/// support.
int _skipField(Uint8List data, int offset, int wireType) {
  switch (wireType) {
    case 0: // varint
      final (_, newOffset) = _readVarint(data, offset);
      return newOffset;
    case 1: // 64-bit fixed
      if (offset + 8 > data.length) {
        throw const FormatException(
          'Malformed protobuf: truncated 64-bit field',
        );
      }
      return offset + 8;
    case 2: // length-delimited
      final (len, newOffset) = _readVarint(data, offset);
      // Validate bounds the same way _readLengthDelimited does.
      _readLengthDelimited(data, newOffset, len);
      return newOffset + len;
    case 5: // 32-bit fixed
      if (offset + 4 > data.length) {
        throw const FormatException(
          'Malformed protobuf: truncated 32-bit field',
        );
      }
      return offset + 4;
    default: // 3/4 = groups (deprecated), or invalid
      throw FormatException('Unsupported protobuf wire type: $wireType');
  }
}

(int value, int newOffset) _readVarint(Uint8List data, int offset) {
  // Accumulate into 32-bit lo/hi halves instead of `result |= byte << shift`:
  // on dart2js a shift of 32+ silently overflows, corrupting large (> 2^32) and
  // negative (10-byte two's-complement) varints. Shifts here never exceed 31
  // bits; halves combine as `hi * 2^32 + lo`, the boundary-safe technique used
  // for uint64 in `special_cbor.dart`.
  var lo = 0; // bits 0..31
  var hi = 0; // bits 32..63
  var shift = 0;
  var terminated = false;
  // A 64-bit varint is at most 10 bytes; bound the loop to reject runaway/
  // unterminated varints in hostile or truncated frames.
  while (offset < data.length && shift < 64) {
    final byte = data[offset++];
    final bits = byte & 0x7F;
    if (shift < 32) {
      lo |= (bits << shift) & 0xFFFFFFFF;
      // A group straddling bit 32 spills its top bits into the high half.
      if (shift > 25) hi |= bits >> (32 - shift);
    } else {
      hi |= (bits << (shift - 32)) & 0xFFFFFFFF;
    }
    if ((byte & 0x80) == 0) {
      terminated = true;
      break;
    }
    shift += 7;
  }
  if (!terminated) {
    throw const FormatException(
      'Malformed protobuf: unterminated or truncated varint',
    );
  }
  lo &= 0xFFFFFFFF;
  hi &= 0xFFFFFFFF;
  // Sign bit (bit 63) set => reproduce the signed (two's-complement) value so
  // negative int32/int64 fields round-trip.
  if ((hi & 0x80000000) != 0) {
    final invLo = (~lo) & 0xFFFFFFFF;
    final invHi = (~hi) & 0xFFFFFFFF;
    final magLo = (invLo + 1) & 0xFFFFFFFF;
    final carry = (invLo + 1) > 0xFFFFFFFF ? 1 : 0;
    final magnitude = ((invHi + carry) & 0xFFFFFFFF) * 0x100000000 + magLo;
    return (-magnitude, offset);
  }
  return (hi * 0x100000000 + lo, offset);
}

/// Returns a view of [len] bytes starting at [offset], validating bounds.
///
/// Throws [FormatException] on a negative or out-of-range length instead of
/// leaking an uncaught [RangeError] from [Uint8List.sublistView].
Uint8List _readLengthDelimited(Uint8List data, int offset, int len) {
  if (len < 0 || offset + len > data.length) {
    throw FormatException(
      'Malformed protobuf: length-delimited field of $len bytes at offset '
      '$offset exceeds buffer of ${data.length} bytes',
    );
  }
  return Uint8List.sublistView(data, offset, offset + len);
}
