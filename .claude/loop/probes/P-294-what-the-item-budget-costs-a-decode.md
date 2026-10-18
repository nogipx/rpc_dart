---
file: packages/core/rpc_dart/.dart_tool/probe/r803_decode_cost.dart
round: 803
commit: f979f886
paths: [packages/core/rpc_dart/lib/src/codec/special_cbor.dart]
status: stale (526c8d52)
promoted: — (a speed measurement; nothing to pin in a test)
---

# P-294 — what the item budget costs a decode

## Measures

Nanoseconds per `CborCodec.decode` of three messages, JIT, after a warm-up:
the median of 7 runs of 200000 decodes (2000 for the list), each arm run
twice.

```
  message               bytes    budget on            budget off
  10 fields             116      1200.9  1202.9       1197.8  1191.4
  100 fields            1421     12655.8 12699.9      12666.9 12618.1
  list of 10000 ints    29730    124025.5 123975.5    120839.5 121092.0
```

About +0.5% on the field maps and +2.5% on the int list, where every
element is one item.

## Control

Budget off is the same build with `_countItem` returning at once (`if (1 >
0) return;`), switched in place and restored. The scope wrapper of the
endpoints is not in this bench: it runs once per message, not per item.
