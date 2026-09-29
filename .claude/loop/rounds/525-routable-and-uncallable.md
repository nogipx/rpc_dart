---
round: 525
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-08
bench: P-160 — new
commit: yes
---

# Round 525 — routable and uncallable

## Target

B-129's item 15, the second split out of that lead after round 524 closed the first.

Lens RPC-08: two places implement one rule and disagree — here a hardcoded constant
against a policy field.

## Hypothesis

`forClientRequest` caps each token at 128 characters while the policy's path limit is
1024, so a long dotted service name the server accepts cannot be called.

## Before

`policy.maxMethodPathLength = 1024`:

```
   32 chars  routable       builds
  120 chars  routable       builds
  128 chars  routable       builds
  129 chars  routable       REFUSED by the caller     <- the band starts
  200 chars  routable       REFUSED by the caller
  600 chars  routable       REFUSED by the caller
 1020 chars  not routable   REFUSED by the caller

CONTROL 1206 chars  not routable   REFUSED by the caller
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b129_15_token_cap.dart`

**CONFIRMED, and now bounded: 129 to roughly 1018 characters is routable and
uncallable.**

Each row asks BOTH questions — would the policy route this path, and will the caller
build it — because a disagreement is only visible when both are read at once. The
control is a name past the policy's own limit: both answers turn negative together, so
the band is genuinely a disagreement rather than the two limits agreeing all along.

## Mechanism

`RpcMetadata.forClientRequest` validates each token against a constant 128.
`parseRpcMethodPath` validates the assembled path against the policy's 1024. Nothing
reconciles them, and the caller's is the tighter.

## After

Nothing. `lib/` is unchanged.

## Canary

n/a — nothing was fixed.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**It is not the one-liner the sketch implies, and that is the round's finding about the
fix rather than about the defect.** `forClientRequest` is a STATIC constructor with no
policy in scope — which is presumably why the constant exists. Two ways out, and they
are different changes:

- thread the limit in, changing the signature of a widely used static; or
- drop the per-token cap and rely on `parseRpcMethodPath`, which already enforces the
  policy's real limit. On that reading the 128 is redundant rather than merely wrong —
  but establishing that needs every caller of `forClientRequest` checked for one that
  never reaches a parse.

**And one question should be answered before either: what was the 128 meant to be?**
An RFC-scale header limit, a gRPC constraint, or an arbitrary guard. Changing a
validation constant without knowing which is how a limit ends up wrong in the other
direction.

Filed as B-198 with the band measured, so whoever answers that question does not have
to re-measure.

## Links

Lens RPC-08. Bench P-160 (new). New lead B-198. Round 521 argued B-129 should be
split; 523-524 did the first item; this is the second.
