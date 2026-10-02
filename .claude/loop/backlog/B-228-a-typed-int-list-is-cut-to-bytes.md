---
status: closed (round 625)
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/codec/special_cbor.dart]
probe: none — audit probe `.dart_tool/probe/correct_serial_focus_test.dart`, superseded by the witness
reason: "FIXED in round 625: wider typed int lists go out as arrays, Uint8ClampedList and ByteData as their bytes. Previously: bench — the CBOR writer sent every TypedData List<int> as Uint8List.fromList(value), keeping only each element's low byte"
---

# B-228 — a typed int list is cut to bytes

Found by the independent audit of 2026-10-02 (codecs).

## The shape

`_writeValue` had `value is TypedData && value is List<int>` ->
`_writeByteString(Uint8List.fromList(value))`. `Uint8List.fromList` keeps the low
8 bits, so `Int16List [1000, -2, 300]` arrived as `[232, 254, 44]`, with no
error, on VM and dart2js alike. `ByteData` is not a `List<int>` and went out as
its `toString()` (`_ByteDataView`).

## Owner decision

—
