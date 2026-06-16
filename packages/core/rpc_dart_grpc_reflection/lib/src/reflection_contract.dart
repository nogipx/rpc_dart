// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';

import 'proto_writer.dart';
import 'reflection_registry.dart';

// gRPC Server Reflection contract (v1alpha + v1).
//
// Protocol: bidi-streaming ServerReflectionInfo method.
// Client sends ServerReflectionRequest, server replies with ServerReflectionResponse.
//
// ServerReflectionRequest wire fields:
//   1 = host (string, ignored)
//   3 = file_by_filename (string, oneof)
//   4 = file_containing_symbol (string, oneof)
//   7 = list_services (string, oneof)
//
// ServerReflectionResponse wire fields:
//   2 = original_request (message, embedded)
//   4 = file_descriptor_response (message, oneof)
//       1 = file_descriptor_proto (repeated bytes)
//   6 = list_services_response (message, oneof)
//       1 = service (repeated message)
//           1 = name (string)
//   7 = error_response (message, oneof)
//       1 = error_code (int32)
//       2 = error_message (string)

/// gRPC Server Reflection contract for [RpcResponderEndpoint].
///
/// Register with both v1 and v1alpha to support all grpcurl versions:
/// ```dart
/// for (final c in ServerReflectionContract.both(registry)) {
///   endpoint.registerServiceContract(c);
/// }
/// ```
class ServerReflectionContract extends RpcResponderContract {
  final RpcReflectionRegistry _registry;

  ServerReflectionContract(
    this._registry, {
    String serviceName = 'grpc.reflection.v1alpha.ServerReflection',
  }) : super(serviceName) {
    addBidirectionalMethod<Uint8List, Uint8List>(
      methodName: 'ServerReflectionInfo',
      requestCodec: RpcBinaryCodec<Uint8List>(
        toBytes: (b) => b,
        fromBytes: (b) => Uint8List.fromList(b),
      ),
      responseCodec: RpcBinaryCodec<Uint8List>(
        toBytes: (b) => b,
        fromBytes: (b) => Uint8List.fromList(b),
      ),
      handler: _handleReflection,
    );
  }

  /// Returns contracts for both v1 and v1alpha reflection service names.
  static List<ServerReflectionContract> both(RpcReflectionRegistry registry) =>
      [
        ServerReflectionContract(
          registry,
          serviceName: 'grpc.reflection.v1.ServerReflection',
        ),
        ServerReflectionContract(
          registry,
          serviceName: 'grpc.reflection.v1alpha.ServerReflection',
        ),
      ];

  Stream<Uint8List> _handleReflection(
    Stream<Uint8List> requests, {
    RpcContext? context,
  }) async* {
    await for (final requestBytes in requests) {
      yield _processRequest(requestBytes);
    }
  }

  Uint8List _processRequest(Uint8List bytes) {
    try {
      return _parseAndDispatch(bytes);
    } catch (_) {
      return _buildErrorResponse(bytes, 2, 'Malformed request');
    }
  }

  Uint8List _parseAndDispatch(Uint8List bytes) {
    var pos = 0;
    String? fileByFilename;
    String? fileContainingSymbol;
    bool listServices = false;

    while (pos < bytes.length) {
      final tagByte = _readVarint(bytes, pos);
      pos = tagByte.$2;
      final tag = tagByte.$1;
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x7;

      if (wireType == 2) {
        final lenResult = _readVarint(bytes, pos);
        pos = lenResult.$2;
        final len = lenResult.$1;
        if (len < 0 || pos + len > bytes.length) {
          return _buildErrorResponse(bytes, 2, 'Malformed request: invalid field length');
        }
        final data = bytes.sublist(pos, pos + len);
        pos += len;

        switch (fieldNumber) {
          case 3:
            fileByFilename = utf8.decode(data);
          case 4:
            fileContainingSymbol = utf8.decode(data);
          case 7:
            listServices = true;
          default:
            break; // skip unknown fields
        }
      } else if (wireType == 0) {
        final v = _readVarint(bytes, pos);
        pos = v.$2;
      } else if (wireType == 1) {
        if (pos + 8 > bytes.length) {
          return _buildErrorResponse(
              bytes, 2, 'Malformed request: truncated 64-bit field');
        }
        pos += 8;
      } else if (wireType == 5) {
        if (pos + 4 > bytes.length) {
          return _buildErrorResponse(
              bytes, 2, 'Malformed request: truncated 32-bit field');
        }
        pos += 4;
      } else {
        // Wire types 3/4 (group start/end) and any other value are not
        // supported. Reject the request instead of dispatching whatever was
        // parsed before the malformed byte.
        return _buildErrorResponse(
            bytes, 2, 'Malformed request: unsupported wire type $wireType');
      }
    }

    if (listServices) {
      return _buildListServicesResponse(bytes);
    } else if (fileByFilename != null) {
      return _buildFileByFilenameResponse(bytes, fileByFilename);
    } else if (fileContainingSymbol != null) {
      return _buildFileContainingSymbolResponse(bytes, fileContainingSymbol);
    } else {
      return _buildErrorResponse(bytes, 5, 'Unknown request type');
    }
  }

  Uint8List _buildListServicesResponse(Uint8List originalRequest) {
    // list_services_response (field 6) → repeated service (field 1) → name (field 1)
    final servicesMsg = ProtoWriter();
    for (final name in _registry.serviceNames) {
      final svcMsg = ProtoWriter();
      svcMsg.writeString(1, name);
      servicesMsg.writeBytes(1, svcMsg.toBytes());
    }

    final response = ProtoWriter();
    _writeOriginalRequest(response, originalRequest);
    response.writeBytes(6, servicesMsg.toBytes());
    return response.toBytes();
  }

  Uint8List _buildFileByFilenameResponse(
    Uint8List originalRequest,
    String filename,
  ) {
    final fileBytesList = _registry.fileByFilename(filename);
    if (fileBytesList == null) {
      return _buildErrorResponse(originalRequest, 5, 'File not found: $filename');
    }
    return _buildFileDescriptorResponse(originalRequest, fileBytesList);
  }

  Uint8List _buildFileContainingSymbolResponse(
    Uint8List originalRequest,
    String symbol,
  ) {
    final fileBytesList = _registry.fileContainingSymbol(symbol);
    if (fileBytesList == null) {
      return _buildErrorResponse(originalRequest, 5, 'Symbol not found: $symbol');
    }
    return _buildFileDescriptorResponse(originalRequest, fileBytesList);
  }

  Uint8List _buildFileDescriptorResponse(
    Uint8List originalRequest,
    List<Uint8List> fileDescriptorProtoBytesList,
  ) {
    // file_descriptor_response (field 4) → file_descriptor_proto (repeated bytes, field 1)
    final fdMsg = ProtoWriter();
    for (final bytes in fileDescriptorProtoBytesList) {
      fdMsg.writeBytes(1, bytes);
    }

    final response = ProtoWriter();
    _writeOriginalRequest(response, originalRequest);
    response.writeBytes(4, fdMsg.toBytes());
    return response.toBytes();
  }

  Uint8List _buildErrorResponse(
    Uint8List originalRequest,
    int errorCode,
    String errorMessage,
  ) {
    // error_response (field 7)
    final errMsg = ProtoWriter();
    errMsg.writeInt32(1, errorCode);
    errMsg.writeString(2, errorMessage);

    final response = ProtoWriter();
    _writeOriginalRequest(response, originalRequest);
    response.writeBytes(7, errMsg.toBytes());
    return response.toBytes();
  }

  // Exposed for unit testing — do not call in production code.
  // ignore: invalid_use_of_visible_for_testing_member
  Uint8List processRequestForTest(Uint8List bytes) => _processRequest(bytes);

  void _writeOriginalRequest(ProtoWriter response, Uint8List originalRequest) {
    // original_request (field 2, message)
    if (originalRequest.isNotEmpty) {
      response.writeBytes(2, originalRequest);
    }
  }
}

/// Reads a varint from [bytes] starting at [pos].
/// Returns (value, newPos).
/// Throws [FormatException] if the varint is malformed (truncated or > 10 bytes).
(int, int) _readVarint(Uint8List bytes, int pos) {
  // Accumulate the low and high 32-bit halves separately so full 64-bit values
  // decode correctly under dart2js, where the native `<<` is a 32-bit op and a
  // shift past bit 31 in a single int would lose the high bits.
  var low = 0;
  var high = 0;
  var shift = 0;
  while (pos < bytes.length) {
    if (shift >= 64) throw const FormatException('Varint exceeds 64 bits');
    final b = bytes[pos++];
    final part = b & 0x7F;
    if (shift < 28) {
      low |= part << shift;
    } else if (shift == 28) {
      low |= (part & 0x0F) << 28;
      high = (part >> 4) & 0x07;
    } else {
      high |= part << (shift - 32);
    }
    if (b & 0x80 == 0) {
      final value = high == 0 ? low : (high * 0x100000000) + (low & 0xFFFFFFFF);
      return (value, pos);
    }
    shift += 7;
  }
  throw const FormatException('Truncated varint');
}
