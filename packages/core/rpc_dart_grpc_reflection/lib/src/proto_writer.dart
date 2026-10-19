// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

/// Protobuf encoder for descriptor.proto, over core's [RpcProtoWriter].
///
/// Leaves out an empty string, empty bytes and a false bool, as proto3 leaves
/// out a default. `rpc_dart_generator` builds the descriptors it embeds
/// through `RpcFileDescriptorBuilder`, so this is the only writer of them.
class ProtoWriter {
  final RpcProtoWriter _out = RpcProtoWriter();

  void writeString(int fieldNumber, String value) {
    if (value.isEmpty) return;
    _out.writeStringField(fieldNumber, value);
  }

  void writeBytes(int fieldNumber, Uint8List value) {
    if (value.isEmpty) return;
    _out.writeBytesField(fieldNumber, value);
  }

  void writeBool(int fieldNumber, bool value) {
    if (!value) return;
    _out.writeVarintField(fieldNumber, 1);
  }

  void writeInt32(int fieldNumber, int value) =>
      _out.writeVarintField(fieldNumber, value);

  Uint8List toBytes() => _out.toBytes();
}
