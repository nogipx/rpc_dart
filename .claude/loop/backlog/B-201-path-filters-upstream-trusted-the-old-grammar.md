---
status: open
round: 504 (measured as part of B-113; split out in the round-540 bookkeeping pass)
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-142
reason: "cost — the going-forward half is fixed and this is what the fix cannot reach: rules and logs written while `/a.b/c` and `/a/b.c` resolved to one method. Plus one sibling never run"
---

# B-201 — path filters upstream trusted a grammar the responder has since tightened

Split out of B-113, which round 504 closed after fixing the collision: `/a.b/c` and
`/a/b.c` no longer resolve to the same method key, because the service and method
grammars are now separate (`kServiceTokenPattern` allows a dot, `kMethodTokenPattern`
does not). Bench `../probes/P-142-do-two-paths-collide.md`.

**What the fix cannot reach.** Anything upstream that matched on the path STRING while
both forms reached one method — a reverse-proxy rule, a gateway ACL, an access-log
filter keyed on `/a.b/`. Those rules were written against the old behaviour and did not
cover `/a/b.`; the responder now refuses the second form, which closes the hole going
forward and does nothing for a rule already trusted or a log already written.

**And one sibling was never run.** `rpc_dart_http`'s responder inherits the fix by
construction — it calls `policy.isValidMethodPath` — but round 504 did not drive it.
RPC-08's question: inheritance by construction is an argument, not a measurement.

## Why it matters

An operator who built an allow-list on the old grammar has a rule that never matched
what it was written to match, and nothing tells them.

## Witness a round would build

For the sibling: the same two paths through `rpc_dart_http`'s responder, asserting the
refusal. For the upstream half there is no witness in this repository — it is a
release-note question, not a defect.

## Owner decision

—
