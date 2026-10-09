---
round: 781
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-14
bench: P-276 — new
commit: yes
release: none
---

# Round 781 — a forwarded context outlives its parent

## Target

The first target of the network-audit skill's `design` mode, rpc-design.md
§1–2: a derived context may shorten a deadline, never extend it, and a
forwarding path keeps deadline and cancellation. `loop.py find --path
packages/core/rpc_dart/lib/src/contracts/context.dart` and `find 'derived
context deadline'` named no record of derivation semantics; B-244 covers a
responder interceptor, not a downstream call. RPC-14 is the lens: work held
past the deadline that bounds it.

## Hypothesis

`createChildWith(timeout:)`, the forwarding call the shipped skill teaches,
and `withTimeout` on an incoming context replace the parent's deadline, so a
downstream server is told more time than the client gave; and
`RpcContext.sanitize` drops the deadline and token, so downstream work runs
after the client has gone.

## Before

P-276, client -> A -> B on two `RpcChannelTransport.pair()` rigs, the client
deadline 200 ms, B waiting 3 s or until its token fires:

```
  arm                      B told     B ran     B ended
  createChild()            175 ms     191 ms    cancelled
  createChildWith(2s)      1998 ms    199 ms    cancelled
  withTimeout(2s)          1999 ms    199 ms    cancelled
  sanitize(ctx)            none       3003 ms   finished
```

The client got DEADLINE_EXCEEDED at about 200 ms in every arm.

Probe: `packages/core/rpc_dart/.dart_tool/probe/deadline_extension.dart`

## Mechanism

`createChildWith` calls `RpcContextBuilder.withTimeout`, which calls
`RpcContext.withTimeout` -> `withDeadline`, a copy with the field replaced:
nothing compares it with the parent's. The two extending arms still stop at
about 200 ms only because `inheritFrom` keeps the parent's token, which A's
responder cancels at A's deadline. `sanitize` builds a fresh context from
headers and trace id alone.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. `createChildWith(2s)` and `withTimeout(2s)` differ from `createChild()`
   by the timeout argument only. `sanitize` differs by more (headers, token,
   request id), so it shows what that path drops, not which drop matters.
2. Yes: 175 ms against 1998 ms told; 191 ms against 3003 ms run.
3. Library side: B's handler reads its own `context.remainingTime` and its
   own token.
4. n/a — nothing is zero; the window (3.3 s) is longer than B's 3 s.
5. n/a.
6. n/a.
7. DEFERRED for an owner decision: what `withDeadline`, `withTimeout` and
   `createChildWith` mean is public API, and the doc of `withDeadline` says
   "a copy with a new deadline", which a min would contradict. In-process
   work is bounded by the token today, which keeps this below the severity
   bar for an unasked change.
8. Not measured, not ruled out: a downstream call over a real network where
   the cancel is lost, and a handler that forwards with its own token.
9. None.
A1. One process; A's and B's responders and callers are separate endpoints
    with default policies.
A2. Latency, introduced by B's own wait; no transport latency is needed.
L1. n/a — no refusal is evidence here.

## Gate

n/a — no code change.

## Not fixed

B-273, awaiting the owner.

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md`.
Probe `../probes/P-276-a-forwarded-context-can-outlive-its-parent.md`.
Lead `../backlog/B-273-the-documented-forwarding-paths-extend-or-drop-the-deadline.md`.
Lead `../backlog/B-244-a-responder-interceptors-deadline-is-not-enforced.md`.
