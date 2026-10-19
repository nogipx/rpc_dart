// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

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
        fromBytes: Uint8List.fromList,
      ),
      responseCodec: RpcBinaryCodec<Uint8List>(
        toBytes: (b) => b,
        fromBytes: Uint8List.fromList,
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
      // Any parse/dispatch failure maps to a gRPC error response, not a crash.
      return _buildErrorResponse(bytes, 2, 'Malformed request');
    }
  }

  /// A malformed request throws [FormatException], which [_processRequest]
  /// answers as one: nothing parsed before the bad byte is dispatched.
  Uint8List _parseAndDispatch(Uint8List bytes) {
    String? fileByFilename;
    String? fileContainingSymbol;
    var listServices = false;

    final reader = RpcProtoReader(bytes);
    while (!reader.atEnd) {
      final (:field, :wireType) = reader.readTag();
      switch ((field, wireType)) {
        case (3, RpcProtoWireType.lengthDelimited):
          fileByFilename = reader.readString();
        case (4, RpcProtoWireType.lengthDelimited):
          fileContainingSymbol = reader.readString();
        case (7, RpcProtoWireType.lengthDelimited):
          reader.readBytes();
          listServices = true;
        default:
          reader.skip(wireType);
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
      return _buildErrorResponse(
        originalRequest,
        5,
        'File not found: $filename',
      );
    }
    return _buildFileDescriptorResponse(originalRequest, fileBytesList);
  }

  Uint8List _buildFileContainingSymbolResponse(
    Uint8List originalRequest,
    String symbol,
  ) {
    final fileBytesList = _registry.fileContainingSymbol(symbol);
    if (fileBytesList == null) {
      return _buildErrorResponse(
        originalRequest,
        5,
        'Symbol not found: $symbol',
      );
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
