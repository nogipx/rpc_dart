---
round: 816
verdict: FIXED
packages: [rpc_dart]
lens: RPC-07
bench: none — the witness test is the measurement
commit: yes
severity: S3
release: changelog
---

# Round 816 — a long deadline on the web cut the reconnect wait

## Target

Network-audit KV-R-07 (peer-supplied deadlines). The peer side is covered:
`long_timer_test` runs on node and pins a 720H `grpc-timeout`, the responder
arms its deadline through `RpcLongTimer`. Swept the class (L-12): every timer
whose duration comes from a deadline, in core and the priority transports.
One did not use `RpcLongTimer`: `RpcRetryInterceptor._withinCall`, the bound
on the wait for a reconnect before an UNAVAILABLE retry (round of 1d29dd37).

## Hypothesis

On the web a call deadline past the timer ceiling (2^31 - 1 ms, about 24.86
days) makes that `Timer(remaining, ...)` fire at once, so the retry does not
wait for the reconnect and the next attempt fails the same way.

## Before

`a_reconnect_waits_no_longer_than_the_call_test`, new case "a deadline past
the web timer ceiling waits like none" (30-day deadline, reconnect 5 s away):

```
  platform   wait before the retry
  VM         >= 4500 ms (passes, the control)
  node       105 ms     (Expected >= 4500, Actual 105)
```

## Mechanism

dart2js arms `Timer` with `setTimeout`, which clamps a delay past the ceiling
to about 1 ms. `RpcLongTimer` exists for exactly this and every other
deadline timer uses it; this site was added later with a plain `Timer`.

## Fix

`timer = RpcLongTimer.create(remaining, expired.complete)`.

## After

```
  node   the new case and long_timer_test: +22, all passed
  VM     the file: +4
```

## Canary

`1 > 0 ? Timer(...) : RpcLongTimer.create(...)` in place: on node the new
case fails, `Expected: a value greater than or equal to <4500> Actual: <105>`.

## The verdict questions

1. Only the platform differs (VM against node), same test.
2. Yes: 105 ms against >= 4500 ms.
3. At the caller: the time the retry interceptor held the call.
4. One run per platform; the gap is 40x, not noise.
5. Quoted.
6. One change, one canary.
7. From the numbers.
8. The peer-side half of KV-R-07 is covered by existing node tests, not
   re-measured here.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze` green. `test:unit`: one red,
`audit_server_deadline_test` "cooperative handler is cancelled when the
deadline passes" (`Expected: 'cancelled' Actual: 'none'`, a 120 ms deadline
under the full gate's load); the test does not use the retry interceptor.
The core suite re-run alone: +2176, green; the file five times alone: green.
Not investigated further.

## Siblings

- websocket, http, isolate, wasm: n/a, swept for deadline-derived timers and
  found none; the deadline timers all live in core
- caller: fixed here (the retry interceptor is caller-side)
- responder: already `RpcLongTimer` (`responder_streams.armDeadline`)
- channel: n/a, no timers of its own

## Not fixed

- `audit_server_deadline_test` went red once under load (Gate).

## Links

Lens `../lenses/RPC-07-web-as-separate-runtime.md`.
