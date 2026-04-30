# rpc_dart_generator

Code generator for caller/responder wrappers in [rpc_dart].

- Generates `Names` (service + method constants, `Names.instance(suffix)` for multiple instances).
- Generates a `final` caller and an `abstract` responder (you implement handlers; `setup()` registers them).
- Codecs: by default inserts `RpcCodec<T>.withDecoder(T.fromJson)`; if `transferMode` is `zeroCopy` no codecs/serialization checks are added.
- Cooperative with other `source_gen` builders: uses `SharedPartBuilder`/`combining_builder` to merge into the same `*.g.dart` instead of writing it directly.

## Annotations
- `@RpcService(name, transferMode?)` — declares service name and default transfer mode (`auto`/`codec`/`zeroCopy`).
- `@RpcMethod(name, kind, requestCodec?, responseCodec?, transferMode?)` — method id, RPC kind, optional codecs and per-method transfer mode.

Per-method `transferMode` overrides the service. In `zeroCopy` codecs are omitted and `IRpcSerializable` check is skipped. In `auto/codec`, if codecs are not provided, `RpcCodec<T>.withDecoder(T.fromJson)` is added (requires `static fromJson`).

## Example (zero-copy, multiple instances)
See `example/lib/calculator_contract.dart` and `example/bin/main.dart`:
```dart
responderEndpoint.registerServiceContract(
  CalculatorContractResponder(
    serviceNameOverride: CalculatorContractNames.instance('alpha'),
  ),
);
responderEndpoint.registerServiceContract(
  CalculatorContractResponder(
    serviceNameOverride: CalculatorContractNames.instance('beta'),
  ),
);

final caller = CalculatorContractCaller(
  RpcCallerEndpoint(transport: callerTransport),
  serviceNameOverride: CalculatorContractNames.instance('beta'),
);
final res = await caller.sum(SumRequest(values: [1, 2, 3]));
```

## Example (auto codec)
`example/lib/calculator_with_codec.dart`:
```dart
@RpcService(name: 'CalculatorCodec')
abstract class ICalculatorCodecContract {
  @RpcMethod(name: 'sum')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});
}
```
`example/bin/main_codec.dart` registers under `Names.instance('json')` and calls it.

## Generate
```bash
fvm dart pub get
fvm dart run build_runner build
```

The builder emits `.rpc_dart.g.part` fragments to the build cache; `source_gen|combining_builder` produces the final `*.g.dart`, allowing rpc_dart output to live alongside other generators (e.g. `json_serializable`) without collisions.

## Transfer modes
- `auto`/`codec`: if codecs are absent → default `RpcCodec<T>.withDecoder(T.fromJson)`; if provided → use them.
- `zeroCopy`: no codecs generated, no `IRpcSerializable` check (any `Object`), intended for zero-copy transports.

### Codec/transfer matrix
| Service transfer | Method transfer | Explicit codecs | Generated codecs | Serialization check |
| --- | --- | --- | --- | --- |
| auto | (inherit) | none | `RpcCodec<T>.withDecoder` | yes |
| auto | (inherit) | set | provided codecs | yes |
| codec | (inherit) | none | `RpcCodec<T>.withDecoder` | yes |
| codec | (inherit) | set | provided codecs | yes |
| zeroCopy | (inherit) | any/none | none | no |
| any | zeroCopy | any/none | none | no |
| any | auto/codec | none | `RpcCodec<T>.withDecoder` | yes |
| any | auto/codec | set | provided codecs | yes |

## Validation
- Signatures must match `kind`: unary → `Future<T> func(T req, {RpcContext? context})`; streams → corresponding `Stream`/`Future`.
- `RpcContext` is the only allowed named parameter.
- In `auto/codec`, types must be serializable (`IRpcSerializable` or primitive), otherwise generation fails.

[rpc_dart]: https://pub.dev/packages/rpc_dart

## gRPC Server Reflection (grpcDescriptor)

The generator automatically emits a `grpcDescriptor` static field on every `Names` class. It contains a `FileDescriptorProto` binary that describes the service schema — suitable for [rpc_dart_grpc_reflection].

```dart
// Generated in calculator_contract.g.dart:
class CalculatorContractNames {
  static const service = 'Calculator';
  // ...
  static final grpcDescriptor = Uint8List.fromList(const [...]);
}
```

Register with `RpcReflectionRegistry` to enable `grpcurl list` / `describe`:

```dart
final registry = RpcReflectionRegistry()
  ..addFileDescriptor(CalculatorContractNames.grpcDescriptor);

registry.attachTo(endpoint);
```

See [rpc_dart_grpc_reflection] for full setup.

[rpc_dart_grpc_reflection]: https://pub.dev/packages/rpc_dart_grpc_reflection
