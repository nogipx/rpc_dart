---
status: awaiting owner
round: 781
commit: 2f469332
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/skills/rpc_dart-core/references/context-and-metadata.md]
probe: packages/core/rpc_dart/.dart_tool/probe/deadline_extension.dart
reason: owner — changing what withDeadline/withTimeout/createChildWith mean is an API decision
rank: 9
---

# B-273 — the documented forwarding paths extend or drop the deadline

The skill's own example for a downstream call,
`incoming.createChildWith(timeout: Duration(seconds: 1))`, REPLACES the
incoming deadline instead of keeping the earlier of the two. So do
`withDeadline` and `withTimeout` on a context that already has one. P-276:
with 200 ms left, B is told 2 s. B still stops at about 200 ms, but only
because the inherited token is cancelled; B's own `remainingTime` check reads
2 s, and if B forwards again with `createChild()` its downstream is told 2 s
too.

The other documented path, `RpcContext.sanitize`, drops the deadline and the
token together with the credentials. P-276: B runs its full 3 s, 2.8 s after
the client has given up. There is no helper that keeps deadline and
cancellation and drops credentials, which is what a forwarding call needs
(gRPC and Go keep the earlier deadline on derivation; see the network-audit
skill's rpc-design.md §1–2).

Options for the owner:

1. `createChildWith(timeout:)` and `RpcContextBuilder.inheritFrom(...)
   .withTimeout` keep the earlier deadline. A child is by name derived; this
   is the narrow fix.
2. Also `RpcContext.withDeadline` / `withTimeout` keep the earlier one, with
   a separate way to replace. Wider, and a behaviour change for anyone who
   extends on purpose.
3. A forwarding helper (e.g. `createChild(dropHeaders: ...)` or a
   `forward()`), keeping deadline, token and trace, and dropping credentials;
   `sanitize` stays a logging helper and its doc says so.

## Owner decision

—
