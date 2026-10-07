---
status: closed (round 711)
round: 711
commit: 45ee7b15
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
probe: .dart_tool/probe/audit_core_ep/credit_probe2.dart
reason: "measured — found by the core audit after round 710, by two auditors independently"
---

# B-259 — pre-bind requests are credited twice

## Seen

A client stream over a channel transport, depth 64, the handler stalling
300 ms once:

```
stall at 31  -> RESOURCE_EXHAUSTED (max: 64 messages)
stall at 95  -> RESOURCE_EXHAUSTED
stall at 64  -> 1000/1000   (control: off the grant-flush point)
depth 8192, stall at 4095, 20000 messages -> RESOURCE_EXHAUSTED
```

Also: an explicit `maxBufferedBytes` below `maxMessageLengthBytes` + 5 +
`maxMetadataBytes` made `advertisedWindowBytes` 1, every stream
stop-and-wait (round 710's formula).

## Owner decision

None needed: both are defects in rounds 709 and 710's own mechanism.
