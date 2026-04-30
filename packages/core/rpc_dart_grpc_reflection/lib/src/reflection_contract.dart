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
  static List<ServerReflectionContract> both(RpcReflectionRegistry registry) => [
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
    // Parse ServerReflectionRequest
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
        // skip varint field
        final v = _readVarint(bytes, pos);
        pos = v.$2;
      } else if (wireType == 1) {
        pos += 8;
      } else if (wireType == 5) {
        pos += 4;
      } else {
        break; // unknown wire type, stop parsing
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
      final svcBytes = svcMsg.toBytes();
      servicesMsg.writeBytes(1, svcBytes);
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
    final fileBytes = _registry.fileByFilename(filename);
    if (fileBytes == null) {
      return _buildErrorResponse(originalRequest, 5, 'File not found: $filename');
    }
    return _buildFileDescriptorResponse(originalRequest, fileBytes);
  }

  Uint8List _buildFileContainingSymbolResponse(
    Uint8List originalRequest,
    String symbol,
  ) {
    final fileBytes = _registry.fileContainingSymbol(symbol);
    if (fileBytes == null) {
      return _buildErrorResponse(
        originalRequest,
        5,
        'Symbol not found: $symbol',
      );
    }
    return _buildFileDescriptorResponse(originalRequest, fileBytes);
  }

  Uint8List _buildFileDescriptorResponse(
    Uint8List originalRequest,
    Uint8List fileDescriptorProtoBytes,
  ) {
    // file_descriptor_response (field 4) → file_descriptor_proto (repeated bytes, field 1)
    final fdMsg = ProtoWriter();
    fdMsg.writeBytes(1, fileDescriptorProtoBytes);

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

  void _writeOriginalRequest(ProtoWriter response, Uint8List originalRequest) {
    // original_request (field 2, message)
    if (originalRequest.isNotEmpty) {
      response.writeBytes(2, originalRequest);
    }
  }
}

/// Reads a varint from [bytes] starting at [pos].
/// Returns (value, newPos).
(int, int) _readVarint(Uint8List bytes, int pos) {
  var result = 0;
  var shift = 0;
  while (pos < bytes.length) {
    final b = bytes[pos++];
    result |= (b & 0x7F) << shift;
    if (b & 0x80 == 0) break;
    shift += 7;
  }
  return (result, pos);
}
