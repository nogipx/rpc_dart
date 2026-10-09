---
round: 653
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: none — the witness test is the measurement; reviewer probes res2_breaker_*.dart
budget: probes 3/5, canaries 3/5
commit: yes
release: changelog
severity: S1
---

# Round 653 — the breaker judged a call by the wrong state

## Target

A resilience review (this round's agent) of `RpcCircuitBreakerInterceptor`,
starting from round 640's open question about half-open.

## Hypothesis

Only the half-open probe decides whether the breaker closes, one probe runs at
a time, and a stream does not hold the breaker hostage.

## Before

```
threshold 2, reset 30 ms; call A admitted while CLOSED, still running
when the breaker opens, half-opens and admits probe P
A succeeds            afterStale=closed     second call while P runs: ADMITTED
A cancelled           afterStale=halfOpen   second call while P runs: ADMITTED
A NOT_FOUND           afterStale=halfOpen   second call while P runs: ADMITTED
A INTERNAL, P ok      afterStale=open       P's success dropped, state stays open
probe is a long-lived stream that delivered 5 messages
                      state=halfOpen        unary calls rejected 10/10
CLOSED, a stream listened to after probeAbandonTimeout
                      received=[]           no onDone within 500 ms: hang
```

## Control

No stale call: `secondCallWhileProbeInFlight=REJECTED`, P's success closes.
A probe stream that closes: closed, 0/10 rejected. Listened in time: `[m1]`,
done.

## Mechanism

RPC-19. An outcome was judged by the breaker's state when the call ENDED, so a
call admitted in an earlier state was taken for the probe -- the code's own
comment said a stale success "must NOT re-close the breaker" and only the open
state honoured it. A stream's outcome was recorded only at its end, so a
subscription admitted as the probe held the single-probe gate for its life.
The abandon timer cancelled the source of a stream nobody had listened to yet
and left the controller open.

## After

Every admission carries a ticket: the breaker's generation (bumped on each
state change) and whether it is the probe. Success and failure count only in
their own generation; only the probe closes, reopens or frees the gate. A
probe stream's first message proves recovery, after which the stream is an
ordinary call. The abandon timer ends the stream with `RpcCancelledException`
(new `StreamBridge.fail`) instead of leaving it open. All six arms read as the
controls.

Semantic change, pinned in `circuit_breaker_cancelled_stream_probe_test`: a
probe stream that delivered a message and was then cancelled now CLOSES the
breaker (it was inconclusive); a probe cancelled before any message is still
inconclusive.

## Canary

Generation not bumped: the counted-failure arm reads `open`. Outcomes judged
by the current state again: the success, cancel and uncounted arms fail.
Without the first-message rule and with the old abandon: the stream arm reads
`halfOpen`, the late listener times out.

## Gate

Recorded in round 657.

## Not fixed

Owner questions from the review: whether retry should honour `RpcRetryInfo`
and `CircuitBreakerOpenException.retryAfter` (today it burns attempts on an
open breaker); whether an uncounted error should reset the failure streak;
whether every error of one stream should count separately.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [..., 653]`.
Test `packages/core/rpc_dart/test/resilience/a_breaker_judges_a_call_by_its_admission_test.dart`.
