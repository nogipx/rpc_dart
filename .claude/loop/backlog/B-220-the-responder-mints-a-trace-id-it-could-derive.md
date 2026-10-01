---
status: closed (round 566)
round: 566
commit: 4541c0c1
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/contracts/context.dart]
probe: P-188
reason: "cost — CONFIRMED at 2 tokens against a control's 0 and FIXED to 1, both ids carrying the same mint number. The stale comment went with it; `base_processor.dart:1302`'s wasteful construction is not this mechanism and moved to B-120's context half"
---

# B-220 — the responder mints a trace id it could derive, for any peer that sends no trace header

Found while answering the owner's question on `B-120` — *why are two ids needed at all* — by
reading the two sides against each other. The caller derives; the responder mints.

`responder_pipeline.dart:2341-2345` adopts the caller's `x-request-id` at construction, so no
token is minted for the request id. Twelve lines later, `:2356-2361`:

```dart
final clientTraceId = context.getHeader('x-trace-id');
if (clientTraceId != null) {
  context = context.withTraceId(clientTraceId);
} else {
  context = context.withTraceId(RpcContextUtils.generateTraceId());
}
```

`generateTraceId()` is one whole `_uniqueToken()` — three `Random.secure()` draws, ~42 us by
`P-179`. The caller side does not do this: `caller_pipeline.dart:143-144` calls
`RpcContextUtils.traceIdFor(context.requestId)`, which derives `trace_<token>` from the request
id it already has and mints nothing.

## Who reaches the else branch

**Any gRPC peer that is not rpc_dart.** `x-request-id` and `x-trace-id` are this library's own
headers, not gRPC's, so a foreign client sends neither: the request id is minted at `:2341`
because there is nothing to adopt, and the trace id is minted again at `:2360`. **Two tokens on
the responder for a call that costs an rpc_dart peer none** — and the second is derivable from
the first by the function next door.

**And one local path.** `base_processor.dart:1281-1284` sends `x-trace-id` only
`if (_context.traceId != null)`, and its null-context branch at `:1302` sends no trace header at
all while setting `x-request-id = RpcContext.empty().requestId` — a whole context constructed to
read one id off it. Through `RpcCallerEndpoint` that branch is unreachable, because
`_ensureCallerContext` always returns a context with a trace id; it is reachable by constructing
a stream processor directly, which the `RpcContext? context` constructor parameter allows.

## Why round 551 reported one token per call

`P-179` ran one arm: an rpc_dart caller through the pipeline, which always sends both headers, so
the `else` at `:2360` was never taken. Its own "what it does not establish" says the streaming
shapes are uncovered; this is a shape it did not have — the peer. The probe needs no change to
see it, only a second arm whose request carries neither header, since a token's last 4 bytes are
its mint number and the count is readable through public API.

## Fix sketch

`RpcContextUtils.traceIdFor(context.requestId)` in place of `generateTraceId()` at `:2360`, which
is what the caller side already does. `traceIdFor` falls back to a fresh token when the request
id is not `req_`-prefixed, so a foreign `x-request-id` behaves exactly as today, and a
responder-minted request id yields a trace derived from it. One line, and the property it changes
— the two ids of one call are correlated — is the property round 551 accepted on the caller side.

## The stale comment comes with it

`context.dart:27-32` still says a token costs three draws *"and the responder mints one only to
replace it"*. Round 551 established that is false and **deliberately left it in place** as the
evidence for how the round-540 decision came to rest on it, pending the lead's return to the
owner. The lead has returned (round-565 review), so the evidence role is discharged and the clause
is now just a false statement about this file's subject. The rest of the comment — why the field
is EAGER, because a lazy field copies as UNSET — is true and load-bearing; only that clause goes.

It belongs to this lead rather than to `B-120` because it is a claim about what the RESPONDER
mints, which is what the one-line fix above changes.

## Witness a round would build

P-179's rig with a second arm: a request whose metadata carries neither `x-request-id` nor
`x-trace-id`, mint count before and after. Expect 2 today and 1 after the fix, with the handler's
two ids sharing a mint number. The canary is the one-line revert.

## Outcome (round 566) — CONFIRMED at two tokens, fixed to one

`../rounds/566-the-side-that-derived-and-the-side-that-minted.md`. Bench `P-188`.

```
                          before   after
  neither header            2        1      <- both ids now carry ONE mint number
  both headers (rpc_dart)   0        0
  a foreign x-request-id     1        1
```

The two mint numbers before — 4 and 5 — are what made it two tokens rather than one count read
twice; after, both ids carry mint 3. `traceIdFor` at `:2360`, which falls back to a fresh token
for an id this library did not issue, so the third arm does not move.

**Breadth swept**: three `generateTraceId()` call sites across every package's `lib/`, and this
was the only defect. The other two are correct by contract — `traceIdFor`'s own fallback, and
`RpcContextBuilder.withGeneratedTraceId()`, whose name promises a fresh id.

**The stale comment is gone** (`context.dart:27-32`), its evidence role discharged by the
round-565 review.

**`base_processor.dart:1302` is NOT this mechanism** and moved to `B-120`: its token count is
already minimal — one id, one token — and what is wasteful there is building a whole
`RpcContext.empty()` for it, which is the context-copy half.

## Owner decision

—
