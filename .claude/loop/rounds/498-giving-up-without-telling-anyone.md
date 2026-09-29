---
round: 498
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-136 — new
commit: yes
---

# Round 498 — giving up without telling anyone

## Target

The audit's fourteenth lead and the last of its damage-class leaders: hidden
timeouts on a call with no deadline. It was `open` when this round took it and is
`awaiting owner` because of what the round found; it is named in `## Not fixed`,
where the question now sits.

Scope decided after measuring, and it splits the lead in two:

- **the abandonment is a defect and is fixed** — a caller that gives up on a
  timeout told the server nothing, so the handler ran on for a caller already
  gone. That is the same defect the cancellation-token path was fixed for, on the
  neighbouring ending, and it needs no policy decision.
- **the implicit 60 s is a policy question and is left open.** Whether a call with
  no deadline should be bounded at all, and by what, changes behaviour for every
  existing caller. The lead's own sketch frames it as an either/or.

Lens RPC-25, as a DUTY: *what does a caller owe the server when it stops
waiting?* Four endings, and the sibling that already answered it is two screens up
in the same file.

## Hypothesis

With no deadline, unary and client-stream wait 60 s, server-stream waits forever,
no `grpc-timeout` is sent, and on expiry the server is never told. Refuted if
something else bounded the wait, or if the handler learned some other way.

## Before

```
no deadline
unary         grpc-timeout=[null]  gave up after 60.0s  TimeoutException  cancelled=0
clientStream  grpc-timeout=[null]  gave up after 60.0s  TimeoutException  cancelled=0
serverStream  grpc-timeout=[null]  gave up after 65.0s  (the PROBE's budget) cancelled=0

with a 500 ms deadline, as the control
unary         grpc-timeout=[498838u]  0.5s  RpcDeadlineExceededException  cancelled=1
clientStream  grpc-timeout=[499374u]  0.5s  RpcDeadlineExceededException  cancelled=1
serverStream  grpc-timeout=[499517u]  0.5s  RpcDeadlineExceededException  cancelled=1
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b107_hidden_timeouts.dart`

Every claim confirmed. `65.0s` is the probe's budget, not a bound — server-stream
has none. And the control shows all the machinery working when a deadline exists,
which is what makes each no-deadline row a comparison rather than an assertion.

## Mechanism

`cancellationNotice` in `UnaryCaller` is assigned only by the token listener, so
the `finally` — which carefully orders notice-then-release — had nothing to send
on a timeout and went straight to `releaseStreamId`. `ClientStreamCaller`'s
`onTimeout` calls `close()`, which cancels the subscription and closes the
processor and sends nothing.

The comment beside the token path states the cost measured when IT was missing: a
3 s job cancelled at 100 ms spent 295 of its 300 work units post-cancellation.
The timeout ending abandons the call just as completely.

## After

```
unary         cancelled=0 -> 1
clientStream  cancelled=0 -> 1
serverStream  cancelled=0 (unchanged — nothing bounds it, so nothing is abandoned)
```

Two lines, each reusing what its file already had. `UnaryCaller` assigns the same
`cancellationNotice` variable, so round 448's ordering applies unchanged: notice
first, release chained onto it, bounded so a wedged send cannot hold the id.
`ClientStreamCaller` calls `_processor.notifyPeerOfAbort`, which exists for
exactly this class of ending — its own doc says `_sendCancellationToServer` is
otherwise reachable only through a cancellation token.

## Canary

`if (1 > 0)` around the unary notice — the WITNESS fails with
`Expected: <1> / Actual: <0>`, "the caller gave up and released the id without a
word, so the handler runs on for a caller that is already gone". Three guards stay
green.

**The client-stream canary UNEXPECTEDLY PASSED, and that is recorded rather than
papered over.** Its witness used a short context deadline, because that is the
only fast way into `ClientStreamCaller.onTimeout` — and on the deadline path the
call SCOPE already cancels the handler, which the probe's control rows show. So
the test measured machinery that already worked. It is now labelled a GUARD, with
the reason in the file, and **the client-stream half's only evidence is the probe
at 60 s**. Canary item 7: a canary that unexpectedly passes means the test is
wrong.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

**One existing test failed and its instrument was repaired, not its assertion.**
`channel_transport_finished_streams_test` read `Actual: <1>` where it wanted 0 —
because the notice rides a frame with `endStream: true`, which marks the stream
finished, and the pruning release is chained onto that notice. Five abandoned
calls read 1, not 5, so it is an in-flight entry and not the accumulation the test
exists to catch. It polls to a deadline now; the assertion is untouched.

## Not fixed

**The implicit 60 s itself**, and the three-way inconsistency around it. B-107
stays open for that, with the numbers in it. The choice the lead names — no
implicit bound anywhere, or one documented default on every shape sent as
`grpc-timeout` — changes behaviour for every existing caller either way.

**The zero-copy unary path** through `_executeUnaryCall`, which the lead names as
a fourth shape with no bound, is not measured.

**`TimeoutException` is still what an explicit `timeout:` argument reports**, and a
guard pins that: it is not a deadline, and the parity work turns on the
distinction.

## Links

Lens RPC-25. Bench P-136 (new). Lead B-107 (open, for the policy half). Round 448
is the notice-then-release ordering this reuses; `notifyPeerOfAbort`'s doc is the
sibling that names this ending.
