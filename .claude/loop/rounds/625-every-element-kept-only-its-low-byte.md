---
round: 625
verdict: FIXED
packages: [rpc_dart]
lens: RPC-07
bench: none — the witness is the measurement: a round trip per typed list, on both runtimes
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S1
---

# Round 625 — every element kept only its low byte

## Target

B-228, from the independent audit of 2026-10-02: the most damaging of the
fourteen findings it filed that were not yet fixed, because it corrupts data
silently on every runtime. The intake's other leads, B-229 to B-240, are filed in
this round.

## Hypothesis

`_writeValue` sends any `TypedData` that is a `List<int>` through
`Uint8List.fromList`, which keeps each element's low byte.

## Before

```
Int8List   [-128, -2, 0, 127]    -> [128, 254, 0, 127]
Int16List  [1000, -2, 300]       -> [232, 254, 44]
Uint16List [1000, 2, 65535]      -> [232, 2, 255]
Int32List  [70000, -70000]       -> [112, 144]
Uint32List [0xDEADBEEF, 1]       -> [239, 1]
ByteData(4)                      -> '_ByteDataView'
```

No error anywhere. The audit read the same on node.

## Control

The same values as a plain `List<int>` round-trip exactly; a `Uint8List`
`[7, 200]` round-trips as a `Uint8List`.

## Mechanism

The branch's comment says it is for `Int8List` and `Uint8ClampedList` "that
dart2js may not recognize as Uint8List", but its test matches every typed int
list. `ByteData` is `TypedData` and not `List<int>`, so it fell through to the
`toString()` fallback.

## After

`Uint8ClampedList` and `ByteData` go out as their bytes (a view, no copy);
every wider typed int list falls through to `List` and goes out as an array.
`a_typed_int_list_keeps_its_values_test.dart`, 9 cases, green on VM and node;
`test/serializers` 135 green.

## Canary

The before table is the witness run against the old branch: all seven
non-`Uint8List` cases red, each with its truncated values.

## Gate

`melos run analyze`, `format:check`, `license:check`, `test:web` (14 suites)
green. `melos run test:unit` red once with the output truncated, then green in
full (exit 0) with the same tree: the intermittent red of rounds 615 and 624,
still unexplained.

## Not fixed

A receiver that read an `Int8List` field as `Uint8List` now gets a `List<int>`.
The old bytes were wrong for any negative element, so nothing correct changes,
but it wants a CHANGELOG line.

## Links

Lead `../backlog/B-228-a-typed-int-list-is-cut-to-bytes.md` — closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` — `applied: [..., 625]`.
Test `packages/core/rpc_dart/test/serializers/a_typed_int_list_keeps_its_values_test.dart`.
