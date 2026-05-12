## 0.4.0

- Added `RpcServiceKind.peer` support: `@RpcService(kind: RpcServiceKind.peer)` generates a peer contract pair (`XxxPeer` abstract class + `XxxPeerCaller` concrete implementation) instead of separate caller/responder.
- Generated `XxxPeer` extends `RpcPeerContract` and registers both incoming handlers and outgoing call methods on the same `RpcPeerEndpoint`.
- Added `grpcDescriptor` flag on `@RpcService`: when `true`, emits `static final grpcDescriptor = Uint8List.fromList(...)` for use with `RpcReflectionRegistry.addFileDescriptor()`.
- Updated to `rpc_dart: ^3.1.0`.

## 0.3.1

- Updated to `rpc_dart: ^3.0.1`.

## 0.3.0

- Generator emits `grpcDescriptor` static field on generated `Names` classes — a `FileDescriptorProto` binary suitable for `RpcReflectionRegistry.addFileDescriptor()`.
- Generator walks `DartType` fields at build time to produce schema bytes for gRPC Server Reflection (Tier 2).
- Updated to `rpc_dart: ^3.0.0`.

## 0.2.1

- Added `@RpcRemoved` support: methods annotated with `@RpcRemoved` generate `@Deprecated` + `throw UnsupportedError` override in caller and are excluded from versioned responder delegation.

## 0.2.0

- Added contract versioning via Dart interface inheritance. Annotate a child interface with `@RpcService` and `implements ParentContract` — the generator detects the version relationship automatically.
- Versioned callers get a `_parent` field holding the parent caller. Methods declared in the child route to the child's service; inherited methods delegate to `_parent`, forming a transparent chain across any number of versions.
- Versioned responders register only the methods declared in their own interface slice, avoiding forced implementation of parent methods that belong to a different responder.

## 0.1.6

- fix: correct custom instance name

## 0.1.5

- bump dependencies

## 0.1.4

- fix: adding bidirectional method

## 0.1.3

- Switch to `SharedPartBuilder` + `combining_builder` to avoid `.g.dart` output collisions with other source_gen builders.

## 0.1.2

- Dependency resolution: allow `analyzer ^8.1.1`.

## 0.1.1

- Move annotations to core library

## 0.1.0

- Added `@RpcService/@RpcMethod` generator with `Names` class (service/method constants, `Names.instance` for multiple instances).
- Generated `final` caller, `abstract` responder; responder registers methods in `setup`, you implement handlers.
- `serviceNameOverride` for caller/responder to run multiple instances of the same service.
- `transferMode` on service/method: `zeroCopy` skips codec generation and serializable checks; `auto/codec` insert `RpcCodec<T>.withDecoder(T.fromJson)` unless explicit codecs provided.
- Caller/responder both honor method-level codecs/modes; custom RPC names supported via `Names` constants.
- Examples: zero-copy, multiple instances, auto-codec.
