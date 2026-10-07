---
round: 682
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-07
bench: none — a dart2wasm probe in node (`.dart_tool/probe/b254_jsview.dart`) and the device suite
commit: yes
release: changelog
---

# Round 682 — a JS-backed view cannot be sliced

## Target

B-254: a client-stream call to a dart2wasm guest fails with INTERNAL on both
platforms; the guest logs `request_deserialization error size: 5 ...
RangeError: Not in inclusive range 0..5: 16`.

## Hypothesis

The lead's: the guest's bytes come from `JSUint8Array.toDart`, and something
slices a view of them with the wrong offset.

## Before

Device suite, `rpc_guest_test.dart`, iOS simulator (Android the same in round
675):

```
RpcStatusException(13): Internal server error    8 of 9
```

## Mechanism

Not in this repository: the SDK. Flutter 3.38.3's
`dart-sdk/lib/_internal/wasm/lib/js_typed_array.dart:893`:

```dart
JSUint8ArrayImpl sublist(int start, [int? end]) {
  final newOffset = offsetInBytes + start;
  final newEnd = RangeErrorUtils.checkValidRange(newOffset, end, lengthInBytes);
```

The absolute `newOffset` is checked against the relative `end` and the
length, so `sublist` of a JS-backed view at a non-zero offset throws, or, where
the numbers happen to fit, returns the wrong bytes. Measured with dart2wasm in
node, a 5-byte CBOR message at offset 16 of a JS-backed list:

```
view JSUint8ArrayImpl off=16 len=5
sublist(3,4) threw RangeError: Invalid value: Not in inclusive range 0..5: 19
decode threw RangeError: Invalid value: Not in inclusive range 0..5: 18
copied Uint8List decode {v: a}
plain decode {v: a}
```

The guest bridge handed `toDart` lists up as they were; the frame decoder
hands payloads up as views into the chunk; `CborCodec` reads a text string with
`sublist`. Unary and server-stream requests happened to land at offset 0.

## Fix

`_RpcWasmBridge._receiveBytes` copies each chunk into a Dart `Uint8List`. The
owner chose the boundary over avoiding `sublist` in core, because it also
covers every user codec that slices its payload.

The cost, measured in the same probe (20000 messages of 205 bytes, three
rounds): the copy is 6.0-6.3 ms in total, about 0.3 us per chunk, against
24.7-26.7 ms to CBOR-decode them. Decoding from the copy costs the same as
decoding from the JS-backed list (26.5 against 24.7-32.8 ms). The owner was
asked before the change.

## After

`rpc_guest_test.dart`: 9 of 9 on the iOS simulator and 9 of 9 on the Android
emulator (emulator-5554), "all four call shapes work against a real guest"
included.

## Canary

Copy removed, guest rebuilt, iOS simulator: `RpcStatusException(13): Internal
server error`, 8 of 9. Restored and rebuilt: 9 of 9.

## The verdict questions

1. Yes: the canary reproduces Before exactly.
2. Yes: the call shape the lead named, on both platforms.
3. Yes: the caller's result from a real guest.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Yes; the owner chose the site, after seeing the cost.
8. None.

## Gate

`analyze`, `test:wasm`, `format:check` green; the device file on both
platforms. `test:unit` not re-run: no workspace package changed.

## Not fixed

The SDK bug itself, upstream. Within this repository's own code
`_receiveBytes` is the only `toDart`, but the browser transports get
JS-backed bytes from their dependencies (`package:web_socket` converts with
`toDart.asUint8List()`), and under dart2wasm they would hit the same `sublist`
in core. Not measured; filed as B-256.

## Links

Lead `../backlog/B-254-a-client-stream-to-a-wasm-guest-fails.md` closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` -- `applied: [..., 682]`.
