---
round: 517
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-08
bench: P-154 — new
commit: yes
---

# Round 517 — the drift that had not happened

## Target

Request metadata assembled in three places — thirty-second in the audit's rank.

Lens RPC-08, shape 1: siblings that should agree. Here the siblings are three
builders for one thing, and the lead asserts they have already diverged.

## Hypothesis

`UnaryCaller.call`, `CallProcessor._sendInitialMetadata` and `ping()` produce
different headers for the same context — specifically, with a null context the
unary copy omits `x-request-id`.

## Before

```
WITH a context:
  unary  (UnaryCaller)           content-type, grpc-accept-encoding, grpc-timeout,
                                 x-request-id, x-route-service, x-trace-id
  server stream (CallProcessor)  content-type, grpc-accept-encoding, grpc-timeout,
                                 x-request-id, x-route-service, x-trace-id
  ping()                         content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id,
                                 x-rpc-ping-timestamp

With NO context (null):
  unary  (UnaryCaller)           content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id
  server stream (CallProcessor)  content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id
  ping()                         content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id,
                                 x-rpc-ping-timestamp
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b125_three_header_builders.dart`

**REFUTED.** The null-context row is the one the lead names, and unary carries
`x-request-id` there — and `x-trace-id` with it.

The two differences that exist are both correct. `grpc-timeout` appears only when a
context carried a deadline, which is what that header means. `ping()` adds
`x-rpc-ping-timestamp` and never carries `grpc-timeout`, because it is a different
operation with its own bound and the extra header is what the pong is measured
against.

## Mechanism

None — there is no defect in the observable.

## After

n/a — nothing changed.

## Canary

n/a for a fix. **What stands in for it is the rig's own false start**, and it is worth
recording because it produced a confident wrong answer: the transport's connection
window-update is a metadata frame too, and it goes FIRST, so "the first metadata
frame" is not the request. Every arm initially reported `x-rpc-conn-window-update`
alone — three identical rows, which read as "they agree" for entirely the wrong
reason. The rig now skips frames carrying nothing but `x-rpc-` bookkeeping.

**A negative that arrives too easily deserves a second look.** Three rows matching
exactly is the expected shape of both the true answer and this particular bug.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**The code IS triplicated, and that part of the lead stands.** Three sites assemble
headers, and the risk it names — *"the next header rule lands in one copy"* — is a
real maintainability argument. What is refuted is that the drift has ALREADY happened,
which was the evidence offered for acting now.

So the fix sketch, one `buildRequestMetadata(service, method, context)`, is a
refactor with no defect behind it. That makes it the owner's preference rather than a
round's target, and it is recorded on the lead rather than done.

**Unmeasured:** the client-stream and bidirectional shapes, a context carrying custom
headers, and the responder's side of the exchange. The three the lead names are the
three that were driven.

## Links

Lens RPC-08. Bench P-154 (new). Negative `checked/C-59`. Lead B-125 (closed —
refuted on its stated consequence).
