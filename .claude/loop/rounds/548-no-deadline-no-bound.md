---
round: 548
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-136 — reused
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
severity: S2
---

# Round 548 — no deadline, no bound

## Target

B-107, an owner decision and therefore the round's first target: **remove the implicit
barrier** — no deadline means no timeout, as the streaming shapes already behave.

Lens RPC-08: four call shapes, three behaviours for the same missing deadline.

## Hypothesis

`timeout ?? remainingTime ?? const Duration(seconds: 60)` in `UnaryCaller` and
`_noDeadlineFallback` in `ClientStreamCaller` bound a call nobody asked to bound, and tell the
server nothing about it.

## Before

```
no deadline
unary         grpc-timeout=[null]  gave up after 60.0s  TimeoutException
clientStream  grpc-timeout=[null]  gave up after 60.0s  TimeoutException
serverStream  grpc-timeout=[null]  gave up after 65.0s  <- the PROBE's budget, not a bound
```

Round 498's table, on the sha B-107 records. Bench
`../probes/P-136-what-bounds-a-call-with-no-deadline.md`.

**The mechanism was reproduced at today's sha by ABLATION rather than by re-running the 60 s
arm** — see the canaries: an implicit bound, shortened so a test can observe it, fires and ends
the call. That is the same mechanism at a different constant, and it costs 400 ms instead of two
minutes.

## Mechanism

Two constants, both removed, and the effective timeout is now nullable:

- `UnaryCaller.call` — `timeout ?? remainingTime`, with an early `return await completer.future`
  when that is null, on BOTH the codec and the zero-copy branches. The zero-copy one was listed
  in the lead as never measured and it had the same fallback applied to it.
- `ClientStreamCaller.finishSending` — `_noDeadlineFallback` deleted, and the same early return.

Nothing else changes: `RpcLongTimer.timeout` still wraps the wait whenever something DID set a
bound, and the deadline path that reports `RpcDeadlineExceededException` and sends `grpc-timeout`
is untouched.

**Breadth, swept by grep for the constant and the field.** Three comments described the bound as
current behaviour and now describe something that does not exist: one in `UnaryCaller` itself
("until the 60s fallback"), and two test headers. Each was corrected rather than deleted — what
they explain is still true, only the clause about the bound was stale. The other hits are a
different 60 s (`halfOpenStreamTimeout`, `backoff maxDelay`) and left alone.

## After

```
no deadline
unary         grpc-timeout=[null]  gave up after 65.0s  <- the probe's budget
clientStream  grpc-timeout=[null]  gave up after 65.0s  <- the probe's budget
serverStream  grpc-timeout=[null]  gave up after 65.0s  <- the probe's budget

the SAME shapes with a real deadline, as the control
unary         grpc-timeout=[496644u]  0.5s  RpcDeadlineExceededException  cancelled=1
clientStream  grpc-timeout=[499680u]  0.5s  RpcDeadlineExceededException  cancelled=1
serverStream  grpc-timeout=[499496u]  0.5s  RpcDeadlineExceededException  cancelled=1
```

**All three shapes now read the same number, and that number is the probe giving up.** Four
shapes, one behaviour, which is what the lead asked for.

The control row is the load-bearing half: with a deadline every piece of machinery still works —
the header is sent, the type is `RpcDeadlineExceededException`, and the handler is cancelled — so
each no-deadline row is a comparison rather than an assertion about a dead code path.

**`cancelled` goes from 1 to 0 on the no-deadline rows, and that is correct.** Round 498 taught
the caller to notify the server when it abandoned a call at the implicit bound; with no
abandonment there is nothing to notify, and the handler runs because the caller is still waiting
for it.

## Canary

Two, one per constant, each restored at 250 ms so a millisecond-scale witness can see it.

```
A. the unary fallback restored
   WITNESS a unary call with no deadline is not bounded
     Expected: 'still waiting'
       Actual: 'TimeoutException after 0:00:00.250000: Call timeout: 0:00:00.250000'

B. the client-stream fallback restored
   WITNESS a client-stream call with no deadline is not bounded
     Expected: 'still waiting'
       Actual: 'TimeoutException: canary'
```

**The witness cannot see the SHIPPED constant, and that is stated in the test.** A 60 s bound is
invisible to a test that waits 400 ms, so what these arms prove is that no bound *within their
window* is armed — the class, not the instance. The 60 s instance is the probe's job, and the
probe is what carries the before and after above. Recorded because an arm that cannot see the
defect reads exactly like a pass.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          REUSE compliant
```

`format:check` failed once on the new test and was re-run green.

Four existing files that mention the fallback were run first and all pass, including
`client_stream_long_deadline_test.dart`, whose whole subject is a deadline longer than the old
bound — its no-deadline arm is a call that gets ANSWERED, so it never needed the bound.

## Not fixed

**The exception TYPE still differs by origin**, which B-107 lists as one of two smaller things
inside the same question: an explicit `timeout:` argument reports `TimeoutException`, a deadline
reports `RpcDeadlineExceededException`. That split is deliberate and pinned by a guard, and this
round did not touch it — but with the implicit fallback gone, `TimeoutException` now has exactly
one source (the argument) instead of two, which is strictly less surprising than before.

**Nothing bounds a call whose peer never answers and whose caller set no deadline.** That is the
decision, not an omission — but it is worth saying plainly that the remedy is now entirely the
caller's, and the library no longer has an opinion.

## Links

Lead `../backlog/B-107-hidden-sixty-second-timeouts.md` — closed by this round; its owner
decision is what the fix carries out.
Bench `../probes/P-136-what-bounds-a-call-with-no-deadline.md` — reused; its no-deadline rows now
read the probe's own budget.
Round `498-giving-up-without-telling-anyone.md` — fixed the abandonment half and split this
question out.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [548]`.
