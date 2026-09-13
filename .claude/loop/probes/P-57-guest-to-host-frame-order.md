---
file: packages/transport/rpc_dart_wasm/example/integration_test/guest_to_host_order_test.dart
round: 365
commit: 760511a5
paths: [packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/ios/**]
status: valid
---

# P-57 — do 10k guest frames arrive in order

Streams 10000 labelled items out of the guest and compares the arrival sequence
against the generated one. Run per platform with
`RPC_WASM_DEVICE=<id> melos run test:wasm:device`.

Compared against `List.generate(n, ...)` rather than by scanning for
inversions, so a swap, a duplicate and a gap all fail the same assertion — and
the length is checked separately, because a reorder that also DROPS would pass a
neighbours-only check.

## Measures

Whether the sequence matches, and how long 10k frames take end to end.

## Control

The two platforms, which guarantee ordering by different mechanisms — and only
one of them is written down:

- **Android**: the guest pushes into `_rpcWasmOutbox`, a JS array, drained in
  order by the driver. FIFO by construction.
- **iOS**: `_rpcWasmSendBytes` does an UNAWAITED `fetch` per frame, so N are in
  flight and the order the Swift scheme handler sees them is WebKit's dispatch
  order — conventional, not contractual.

```
platform  frames  in order  elapsed
android   10000   yes       2161-2808ms
ios       10000   yes       5006-14695ms
```

The iOS row is the one worth having: it is the first measurement in this
repository that the undocumented FIFO convention actually holds, over 10k
frames, rather than being assumed.

Ordering is not a nicety here — `RpcChannelTransport` reassembles a byte STREAM,
so two frames swapped on the wire are corruption, not a reordered pair: the
second frame's header is read from the middle of the first frame's payload.
