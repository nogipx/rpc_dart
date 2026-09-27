---
status: decided by owner (round 445)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
probe: —
reason: cost — split out of B-70 item 13; a bench has to show a header being dropped that the policy admits
---

# B-72 — RpcContext's header limits are a second home, wired to nothing

`RpcContext` declares four private limits of its own —
`_maxHeaderCount` 128, `_maxHeaderNameLength` 128, `_maxHeaderValueLength`
8*1024, `_maxTotalHeaderBytes` 64*1024 (`contracts/context.dart:11-14`) —
NUMERICALLY EQUAL to `RpcSecurityPolicy`'s defaults
(`security_policy.dart:197-206`) and connected to nothing. `_sanitizeHeaders`
(`:238`) `continue`s past an over-long header and `break`s out at the count or
byte ceiling (`:259-262`), discarding the remainder with no signal.

**The equality is what hides it.** Raise `maxHeaders` past 128 and the context
still truncates at 128; the two agreeing today is exactly why nobody notices one
of them is unreachable. Same shape as B-67, where the method-path limit is
monotone downward only.

What a bench has to show: a caller that sets a raised policy, builds a context
past the old ceiling, and finds the headers absent at the peer with no error on
either side. The severity turns on whether the drop is silent to the SENDER,
which is what `break` makes it.

Not yet established: whether any transport re-checks the count on the way out,
which would turn a silent drop into a refusal.

Round 444 named this the first of B-70's three to take, because it is one round
and the consequence is a caller believing it sent something it did not.

## Owner decision

**Take it. Delete the second home, and make the overflow LOUD.**

- The four private constants go. `RpcContext` reads the limits from
  `RpcSecurityPolicy`, so raising `maxHeaders` raises what the context will
  carry. One source, and the equality that hides the bug stops existing.
- `_sanitizeHeaders` stops `continue`-ing and `break`-ing past what it cannot
  carry. A caller that exceeds the limit is TOLD; silent truncation is the
  actual damage in this lead — a caller believing it sent what it did not.

The repo has the precedent for throwing here: `fix(rpc_dart)!: require
printable-ASCII metadata header values` made the same trade, an
`ArgumentError` in place of a silent mangle. Match that shape rather than
inventing a new one.

Still answer the lead's open question first — whether any transport re-checks
the count on the way out — because if one does, the drop is already a refusal
somewhere and the fix is smaller than it looks.

Raising the effective ceiling means more headers on the wire than before; note
it in the CHANGELOG.
