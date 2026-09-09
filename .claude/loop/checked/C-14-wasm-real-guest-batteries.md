---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
scope: [wasm, a real guest on a device]
---

# C-14 — wasm: three batteries against a real guest

A real dart2wasm guest on a device: unary, a 25-item server stream, and a 4 MiB
response reassembled through the framing layer. The guest is `isClient: false`,
so the host must be `isClient: true`.

The built `.wasm` is deliberately NOT committed: it goes stale the moment core
changes, and the `test:wasm:device` target builds it.

## Control

A guest that replies with garbage: the battery goes red, so it does look at the
content of the reply.
