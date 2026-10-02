---
status: open
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/codec/special_cbor.dart, packages/core/rpc_dart/test/serializers/cbor_parity_test.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/correct_serial_focus_test.dart`, not yet registered
reason: "cost — dart2js sends -0.0 as integer 0, trailing bytes after the top-level item are ignored, and unassigned simple values decode as ints"
---

# B-240 — three CBOR edges off the RFC

Found by the independent audit of 2026-10-02 (codecs), reproduced before filing.

## Measured

```
-0.0 on node   bytes a1617600 -> 0 (sign lost)     VM a16176fb80.. -> -0.0
node decoding the VM's bytes                        -0.0 (sign kept)
glued {a:1}{b:2}         decode -> {a: 1}, the rest dropped silently
truncated by one byte    FormatException
a16176f0 (simple 16)     -> {v: 16}
a16176f818 (not well-formed)   -> {v: 24}
```

`cbor_parity_test.dart` skips -0.0 as a platform limitation; the sign is visible
before encoding on dart2js (`isNegative` true), so only the encoder drops it.

## Owner decision

—
