---
status: closed (round 715)
round: 711
commit: 45ee7b15
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
probe: .dart_tool/probe/audit_core_fc/ss_probe.dart
reason: "measured — found by the core flow-control audit"
---

# B-262 — the connection window alone has no message credit

## Seen

Message credit rides on the per-stream grant, so with
`flowControlWindowBytes: null` and the connection window on, a sender is paced
by connection bytes only and the depth fails small-message streams as before
round 709:

```
server stream, 1000 small items, 1 ms per item, depth 64
both windows       OK 1000
connection only    ERROR at 66: more than 64 un-consumed messages
```

## Why it matters

A legal but unusual configuration. Not a regression.

## What a round owes this

Either carry message credit on the connection-level frame for streams with no
per-stream window, or document that the depth is enforced without credit there.

## Owner decision

Owner, 2026-10-08: document it. The policy doc and the skill now say there is no message credit with only the connection window on (round 715).
