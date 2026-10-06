---
status: open
round: 675
commit: 32974d54
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/transport/rpc_dart_wasm/lib/src/wasm/rpc_wasm.dart, packages/transport/rpc_dart_wasm/example/integration_test/rpc_guest_test.dart]
probe: packages/transport/rpc_dart_wasm/example/integration_test/zz_probe_collect.dart
reason: "bench — found by round 675's device suite, pre-existing: red at 32974d54 too. The guest's own error is captured; the mechanism is not yet read"
---

# B-254 — a client-stream call to a dart2wasm guest fails with INTERNAL

## Seen

`rpc_guest_test` "all four call shapes work against a real guest", on the iOS
simulator and the Android emulator: unary and server stream pass, the client
stream `Echo/Collect` gets `RpcStatusException(13): Internal server error`.

Red at the session-start commit `32974d54` as well (a worktree, guest rebuilt
from that commit), so it predates rounds 664-675.

## Measured

`zz_probe_collect.dart` with the guest temporarily given a `ConsoleOutput`
logger, both platforms:

```
ERRO rpc.peer.Echo.Collect.ClientResponder.StreamProcessor request_deserialization error
     [methodPath: /Echo/Collect, streamId: 1, size: 5]
     err=RangeError: Invalid value: Not in inclusive range 0..5: 16
```

A 5-byte "message" reaches the codec. `RpcCodec`'s CBOR decoder indexes its own
bytes, so the RangeError (index 16 of 5) points at the message bytes handed to
it, not at the decoder. The same call over the VM channel pair passes.

## Why it matters

Client streaming does not work against any dart2wasm guest, on either platform.

## What a round owes this

Where the 5-byte view comes from: the guest receives `JSUint8Array.toDart`
bytes, whose `buffer`/`offsetInBytes` differ from a VM list's. Look for a
`buffer`-based view that drops `offsetInBytes` on the client-stream path
(buffered payloads before bind), then a VM witness that reproduces it with a
non-zero-offset view.

## Owner decision

—
