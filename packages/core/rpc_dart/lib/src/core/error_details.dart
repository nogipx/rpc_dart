// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'protobuf.dart';

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
    final out = RpcProtoWriter()..writeStringField(1, typeUrl);
    final value = encode();
    if (value.isNotEmpty) out.writeBytesField(2, value);
    return out.toBytes();
  }

  /// Decodes an Any message into a typed [RpcErrorDetail].
  /// Returns [RpcRawErrorDetail] for unknown types.
  static RpcErrorDetail decodeAny(Uint8List data) {
    var typeUrl = '';
    var value = Uint8List(0);
    _readFields(data, (field, r) {
      switch (field) {
        case (1, RpcProtoWireType.lengthDelimited):
          typeUrl = r.readString();
        case (2, RpcProtoWireType.lengthDelimited):
          value = r.readBytes();
        default:
          return false;
      }
      return true;
    });

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
  final out = RpcProtoWriter();
  if (code != 0) out.writeVarintField(1, code);
  if (message.isNotEmpty) out.writeStringField(2, message);
  for (final detail in details) {
    out.writeBytesField(3, detail.encodeAsAny());
  }
  return out.toBytes();
}

/// Decodes a `google.rpc.Status` message from `grpc-status-details-bin`.
/// Returns (code, message, details).
({int code, String message, List<RpcErrorDetail> details}) decodeRpcStatus(
  Uint8List data,
) {
  var code = 0;
  var message = '';
  final details = <RpcErrorDetail>[];
  _readFields(data, (field, r) {
    switch (field) {
      case (1, RpcProtoWireType.varint):
        code = r.readVarint();
      case (2, RpcProtoWireType.lengthDelimited):
        message = r.readString();
      case (3, RpcProtoWireType.lengthDelimited):
        details.add(RpcErrorDetail.decodeAny(r.readBytes()));
      default:
        return false;
    }
    return true;
  });
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
    final out = RpcProtoWriter();
    for (final v in violations) {
      final violation = RpcProtoWriter();
      if (v.field.isNotEmpty) violation.writeStringField(1, v.field);
      if (v.description.isNotEmpty) {
        violation.writeStringField(2, v.description);
      }
      out.writeBytesField(1, violation.toBytes());
    }
    return out.toBytes();
  }

  static RpcBadRequest _decode(Uint8List data) {
    final violations = <RpcFieldViolation>[];
    _readFields(data, (field, r) {
      if (field != (1, RpcProtoWireType.lengthDelimited)) return false;
      violations.add(_decodeFieldViolation(r.readBytes()));
      return true;
    });
    return RpcBadRequest(violations);
  }

  static RpcFieldViolation _decodeFieldViolation(Uint8List data) {
    var field = '';
    var description = '';
    _readFields(data, (tag, r) {
      switch (tag) {
        case (1, RpcProtoWireType.lengthDelimited):
          field = r.readString();
        case (2, RpcProtoWireType.lengthDelimited):
          description = r.readString();
        default:
          return false;
      }
      return true;
    });
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
    // Field 1, retry_delay, is a google.protobuf.Duration: seconds (int64) and
    // nanos (int32).
    final duration = RpcProtoWriter();
    final seconds = retryDelay.inSeconds;
    final nanos = (retryDelay.inMicroseconds - seconds * 1000000) * 1000;
    if (seconds != 0) duration.writeVarintField(1, seconds);
    if (nanos != 0) duration.writeVarintField(2, nanos);
    return (RpcProtoWriter()..writeBytesField(1, duration.toBytes())).toBytes();
  }

  static RpcRetryInfo _decode(Uint8List data) {
    var seconds = 0;
    var nanos = 0;
    _readFields(data, (field, r) {
      if (field != (1, RpcProtoWireType.lengthDelimited)) return false;
      _readFields(r.readBytes(), (durationField, d) {
        switch (durationField) {
          case (1, RpcProtoWireType.varint):
            seconds = d.readVarint();
          case (2, RpcProtoWireType.varint):
            nanos = d.readVarint();
          default:
            return false;
        }
        return true;
      });
      return true;
    });
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
    final out = RpcProtoWriter();
    for (final entry in stackEntries) {
      out.writeStringField(1, entry);
    }
    if (detail.isNotEmpty) out.writeStringField(2, detail);
    return out.toBytes();
  }

  static RpcDebugInfo _decode(Uint8List data) {
    final entries = <String>[];
    var detail = '';
    _readFields(data, (field, r) {
      switch (field) {
        case (1, RpcProtoWireType.lengthDelimited):
          entries.add(r.readString());
        case (2, RpcProtoWireType.lengthDelimited):
          detail = r.readString();
        default:
          return false;
      }
      return true;
    });
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
    final out = RpcProtoWriter();
    if (reason.isNotEmpty) out.writeStringField(1, reason);
    if (domain.isNotEmpty) out.writeStringField(2, domain);
    // map<string, string>: repeated { string key = 1; string value = 2; }
    for (final entry in metadata.entries) {
      final mapEntry = RpcProtoWriter()
        ..writeStringField(1, entry.key)
        ..writeStringField(2, entry.value);
      out.writeBytesField(3, mapEntry.toBytes());
    }
    return out.toBytes();
  }

  static RpcErrorInfo _decode(Uint8List data) {
    var reason = '';
    var domain = '';
    final metadata = <String, String>{};
    _readFields(data, (field, r) {
      switch (field) {
        case (1, RpcProtoWireType.lengthDelimited):
          reason = r.readString();
        case (2, RpcProtoWireType.lengthDelimited):
          domain = r.readString();
        case (3, RpcProtoWireType.lengthDelimited):
          final (key, value) = _decodeMapEntry(r.readBytes());
          if (key != null) metadata[key] = value ?? '';
        default:
          return false;
      }
      return true;
    });
    return RpcErrorInfo(reason: reason, domain: domain, metadata: metadata);
  }

  static (String?, String?) _decodeMapEntry(Uint8List data) {
    String? key;
    String? value;
    _readFields(data, (field, r) {
      switch (field) {
        case (1, RpcProtoWireType.lengthDelimited):
          key = r.readString();
        case (2, RpcProtoWireType.lengthDelimited):
          value = r.readString();
        default:
          return false;
      }
      return true;
    });
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

/// Reads every field of [data], handing each (field number, wire type) to
/// [read]; a field it does not take (returns false) is skipped, as protobuf's
/// forward-compatibility rule requires.
void _readFields(
  Uint8List data,
  bool Function((int, int) field, RpcProtoReader reader) read,
) {
  final reader = RpcProtoReader(data);
  while (!reader.atEnd) {
    final (:field, :wireType) = reader.readTag();
    if (!read((field, wireType), reader)) reader.skip(wireType);
  }
}
