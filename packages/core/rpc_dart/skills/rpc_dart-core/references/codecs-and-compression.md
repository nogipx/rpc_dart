<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Codecs and compression

A codec turns a message into bytes and back. Whether a method uses codecs is
decided by its `RpcDataTransferMode` and by whether codecs were passed.
Compression is a separate, per-message step applied to the encoded bytes.

## Rules

- Pass **both** `requestCodec` and `responseCodec`, or **neither**. One without
  the other throws `ArgumentError` (in `auto` and `codec` modes).
- No codecs means zero-copy: objects are passed as-is. That requires a transport
  with `supportsZeroCopy == true`; on any other transport the call throws
  `ArgumentError` and a zero-copy responder method answers `UNIMPLEMENTED`.
- Network transports (http, http2, websocket, wasm, `RpcChannelTransport.pair`)
  have `supportsZeroCopy == false`. Methods used over them need codecs.
- Responder and caller must agree: same codec format for the same method.
- `RpcCodec<T>` needs `T extends IRpcSerializable` and a decoder. Without a
  decoder it can encode but `deserialize` throws.
- `package:rpc_dart/rpc_dart.dart` re-exports `dart:typed_data`; do not import
  it again in the same file (the analyzer reports the import as unnecessary).

## Transfer modes

Set per contract (`dataTransferMode:` on `RpcResponderContract` /
`RpcCallerContract`, `responderDataTransferMode:` / `callerDataTransferMode:` on
`RpcPeerContract`), or per method via `@RpcService` / `@RpcMethod` when
generating.

| Mode | Codecs given | Codecs omitted |
| --- | --- | --- |
| `auto` (default) | serialize; but a **unary** call on a zero-copy transport still passes objects and skips the codecs | zero-copy |
| `codec` | always serialize, on every transport | `ArgumentError` |
| `zeroCopy` | ignored, zero-copy | zero-copy |

Use `codec` when the codec must run even in-process: to apply the field
filtering in `toJson`, or to have `maxMessageLengthBytes` (see
`security-and-flow-control.md`) measure real bytes. Under `auto`, a unary call
over `memoryPair()` or an isolate transport has no bytes to measure.

| Transport | `supportsZeroCopy` |
| --- | --- |
| `RpcChannelTransport.memoryPair()` | true |
| `RpcChannelTransport.pair()` | **false** (real frame encoding, in memory) |
| `rpc_dart_isolate` on the VM | true (objects still cross via `SendPort`, so they are copied; "zero-copy" means "no codec") |
| `rpc_dart_isolate` on web | false |
| http, http2, websocket, wasm | false |

## Interfaces

| Type | Use |
| --- | --- |
| `IRpcSerializable` | Interface: `Map<String, dynamic> toJson()`. Add a `fromJson` factory by convention. |
| `IRpcCodec<T>` | Interface: `Uint8List serialize(T)`, `T deserialize(Uint8List)`. Implement for any format. `deserialize` may be given a VIEW into a larger buffer: slice it with `Uint8List.sublistView`, or copy it with `Uint8List.fromList`, never with `sublist`. Under dart2wasm in a browser the bytes can be JS-backed, and `sublist` on such a view at a non-zero offset counts the offset twice (an SDK bug), returning wrong bytes or throwing. |
| `RpcCodec<T extends IRpcSerializable>` | CBOR of `toJson()`. `const RpcCodec([fromJson])` or `const RpcCodec.withDecoder(fromJson)`. Static `RpcCodec.fromBytes(bytes:, fromJson:)`. |
| `RpcBinaryCodec<T>` | Adapter: `const RpcBinaryCodec(toBytes:, fromBytes:)`. Use for protobuf or any existing byte format; `T` need not implement `IRpcSerializable`. |
| `CborCodec` | Static `encode(Map<String, dynamic>)` / `decode(Uint8List)` used by `RpcCodec`. |

```dart
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';

final class User implements IRpcSerializable {
  const User({required this.id, required this.name, required this.createdAt});

  final int id;
  final String name;
  final DateTime createdAt;

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as int,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };
}

const userCodec = RpcCodec<User>.withDecoder(User.fromJson);

// Any byte format. The same shape fits protobuf:
// toBytes: (m) => m.writeToBuffer(), fromBytes: Msg.fromBuffer.
final textCodec = RpcBinaryCodec<String>(
  toBytes: (s) => Uint8List.fromList(utf8.encode(s)),
  fromBytes: utf8.decode,
);

final class UsersResponder extends RpcResponderContract {
  UsersResponder()
    : super('Users', dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    addUnaryMethod<RpcInt, User>(
      methodName: 'get',
      handler: _get,
      requestCodec: RpcInt.codec,
      responseCodec: userCodec,
    );
    addUnaryMethod<String, String>(
      methodName: 'shout',
      handler: _shout,
      requestCodec: textCodec,
      responseCodec: textCodec,
    );
  }

  Future<User> _get(RpcInt id, {RpcContext? context}) async =>
      User(id: id.value, name: 'Ada', createdAt: DateTime.utc(2026));

  Future<String> _shout(String s, {RpcContext? context}) async =>
      s.toUpperCase();
}
```

## Primitives

Wrappers for sending a bare value with `RpcCodec`. Each has a `const`
constructor, a `.value`, a `fromJson`, and a static `.codec` getter. Wire form
is `{'v': value}`.

| Type | Wraps | Extension |
| --- | --- | --- |
| `RpcString` | `String` | `'x'.rpc` |
| `RpcInt` | `int` | `1.rpc` |
| `RpcDouble` | `double` | `1.5.rpc` |
| `RpcNum` | `num` | `someNum.rpc` |
| `RpcBool` | `bool` | `true.rpc` |
| `RpcNull` | nothing (`const RpcNull()`) | none |
| `RpcList<T extends IRpcSerializable>` | `List<T>` | none; **no `.codec`** |

`RpcList` has no codec getter. Build one from the element decoder:

```dart
final namesCodec = RpcCodec<RpcList<RpcString>>(
  RpcList.fromJson<RpcString>(RpcString.fromJson),
);

RpcList<RpcString> names() => RpcList.from(['a'.rpc, 'b'.rpc]);
```

## Compression

- Algorithm registry is global and static: `RpcGrpcCompression`. Names are
  case-insensitive. `register(encoding, codec)` replaces any existing codec;
  `unregister(encoding)` removes it. Register at startup, before calls.
- Where `dart:io` exists (VM, Flutter native), `gzip` is registered
  automatically. On web nothing is registered; add a codec, e.g. the gzip codec
  from the `rpc_dart_compression` package (see its README).
- Requests are compressed only when the caller endpoint was created with
  `compressionEnabled: true` (`RpcCallerEndpoint`, `RpcPeerEndpoint`; default
  `false`). It then declares `grpc-encoding` (gzip if registered) and advertises
  every registered encoding in `grpc-accept-encoding`.
- Responses are compressed by the responder when the caller advertised a
  registered non-identity encoding. With `compressionEnabled: false` the caller
  advertises `identity` only, so responses are not compressed either.
- Each message is sent compressed only if that makes it smaller, so tiny or
  incompressible messages go out plain under a compressed `grpc-encoding`.
- Compression is skipped entirely when `transport.supportsZeroCopy` is true.
- A request with an unregistered `grpc-encoding` is refused with
  `UNIMPLEMENTED`, listing the supported encodings.

Custom algorithm: extend or implement `RpcCompressionCodec`
(`const RpcCompressionCodec()`), which has two members:
`Uint8List compress(Uint8List data)` and
`Uint8List decompress(Uint8List data, {int? maxOutputBytes})`.

`decompress` must stop and throw `RpcStatusException(RpcStatus.resourceExhausted, ...)`
**before** producing more than `maxOutputBytes` (when non-null). Anything else
thrown is treated as malformed input (`INTERNAL`). Ignoring the limit lets a
small compressed message allocate unbounded memory.

```dart
final class ChunkedCompressionCodec extends RpcCompressionCodec {
  const ChunkedCompressionCodec(this._deflate, this._inflateChunks);

  final Uint8List Function(Uint8List data) _deflate;

  /// Must inflate lazily, one chunk at a time.
  final Iterable<Uint8List> Function(Uint8List data) _inflateChunks;

  @override
  Uint8List compress(Uint8List data) => _deflate(data);

  @override
  Uint8List decompress(Uint8List data, {int? maxOutputBytes}) {
    final out = BytesBuilder(copy: false);
    for (final chunk in _inflateChunks(data)) {
      out.add(chunk);
      if (maxOutputBytes != null && out.length > maxOutputBytes) {
        throw RpcStatusException(
          RpcStatus.resourceExhausted,
          'Decompressed message exceeds $maxOutputBytes bytes',
        );
      }
    }
    return out.takeBytes();
  }
}

RpcCallerEndpoint compressedCaller(
  RpcCompressionCodec codec,
  IRpcTransport clientTransport,
) {
  RpcGrpcCompression.register('deflate-x', codec); // once, at startup
  return RpcCallerEndpoint(
    transport: clientTransport,
    compressionEnabled: true,
  );
}
```

Both peers must have the encoding registered: a caller declaring an encoding
the responder lacks gets `UNIMPLEMENTED` on every call.

## Pitfalls

- Default mode is `auto`, not `zeroCopy`. Codecs omitted on a network transport
  fail at call time, not at registration.
- `RpcCodec<T>()` with no decoder: encoding works, decoding throws
  `RpcStatusException`. Use `withDecoder` for anything that is received.
- Under `auto`, unary calls on in-process and VM isolate transports skip your
  codecs. A `toJson` that drops secret fields does not protect them there; use
  `RpcDataTransferMode.codec`.
- `RpcCodec` writes integers only in the range -2^53..2^53-1 (exact on web
  too). Outside it, encoding throws `ArgumentError` on the VM. Send big ids as
  strings.
- `toJson` values must be CBOR-friendly: null, bool, num, String, `Uint8List`,
  List, Map, or nested `IRpcSerializable`. A `DateTime` or enum is written as its
  `toString()` and arrives as a `String`; convert explicitly.
- Static `.codec` getters (`RpcString.codec`, ...) are not `const`; do not use
  them in const contexts.
- Do not enable compression to "save memory" in-process: it does nothing on
  zero-copy transports.
