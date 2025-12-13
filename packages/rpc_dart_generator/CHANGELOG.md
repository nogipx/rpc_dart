## 0.1.2
- Dependency resolution: allow `analyzer ^8.1.1` (drop `source_gen_test` which required analyzer 9).

## 0.1.1
- Move annotations to core library

## 0.1.0
- Added `@RpcService/@RpcMethod` generator with `Names` class (service/method constants, `Names.instance` for multiple instances).
- Generated `final` caller, `abstract` responder; responder registers methods in `setup`, you implement handlers.
- `serviceNameOverride` for caller/responder to run multiple instances of the same service.
- `transferMode` on service/method: `zeroCopy` skips codec generation and serializable checks; `auto/codec` insert `RpcCodec<T>.withDecoder(T.fromJson)` unless explicit codecs provided.
- Caller/responder both honor method-level codecs/modes; custom RPC names supported via `Names` constants.
- Examples: zero-copy, multiple instances, auto-codec.
