---
round: 587
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-25
bench: P-207 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: none
severity: S3
---

# Round 587 — eight calls, eight errors

## Target

`B-143`'s last claim, the one round 539 named and did not measure: in-flight calls
each log an error during an orderly close.

Lens RPC-25 in its duty form, and the sibling is the next branch down in the same
`try`: *what does this transport log when a call ends for a reason THIS SIDE caused?*
`http.RequestAbortedException` already answers it — `internal`, with the reason
written out: *"logging it at error would make every ordinary cancellation look like
a failure"*. A close is the same event with a different trigger.

## Hypothesis

`close()` closes the client it owns, every parked request fails with a
`ClientException`, and the generic catch logs at `error` once per call.

## Before

```
8 calls in flight   errors before 0   errors after 8
1 call  in flight   errors before 0   errors after 1
0 calls             errors before 0   errors after 0
                    last error: HTTP request failed for [streamId: 11]
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b143_what_an_orderly_close_logs.dart`.

**"Each" is the claim, so the arm has to SCALE.** `8 / 1 / 0` is what makes this per
call rather than one record for a close; the 0-call arm says the records come from
the calls and not from `close()`.

## Mechanism

`close()` sets `_isClosed` before `_httpClient.close()`, so the flag is already a
reliable signal by the time each parked request lands in the catch — and the catch
did not read it.

## After

```
8 calls in flight   errors 0   internal 16
1 call  in flight   errors 0   internal 2
0 calls             errors 0   internal 0
```

**`internal 16` is load-bearing, and so is the probe's `minLevel`.** With the default
level the guarded `internal` call is filtered and a count of zero errors cannot be
told from a log that was DELETED. Two records per call says the event is still
recorded and only the level moved; the status a consumer sees is untouched, since it
comes from `_closedDuringCall` by way of `closeAll`.

## Canary

```
the `_isClosed` branch switched off
  WITNESS closing under 8 calls logs no error at all
    Expected: <0>
      Actual: <8>
  CONTROL one call, so the count is known to scale
    Expected: <0>
      Actual: <1>
```

`GUARD a real failure is still an error` stays green under it — a refused connection
with the transport OPEN still logs at `error`, which is the half the fix must not
have taken with it.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +211
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2226 / 2226, REUSE compliant
```

**The gate went red twice before it went green, on a core test this round cannot
reach**, and the red is filed rather than re-run away:

```
rpc_dart  the_window_counts_wire_bytes_test.dart:192
          "a half-closed request does not end the response's window"
          Expected: <1>  Actual: <0>

the file alone        7 of 7 pass
the third gate run    rpc_dart +1876 ~1, SUCCESS
load average          11.37
```

Four things make this a flake rather than a regression: the change is in another
package and cannot touch core's flow control; the file passes alone; the same gate
ran green five times in rounds 582-586; and the load is 11.37 against `config.md`'s
quiet-machine bar. Filed as `B-224` with the reasoning, because the assertion is a
PARK — a state that reads `0` both when the window works and the send has not been
attempted yet, and when the window does not work and the send already drained.

## Not fixed

**The responder half of this package has its own close path** and no arm touches it.

**No arm reads what a CONSUMER sees.** The status is unchanged by construction — only
the log level moved — and the round does not claim to have verified the consumer
side beyond the GUARD.

**The load flake is filed, not fixed.** This round's own probes drove the load that
exposed it, which is the one thing about it this round can be sure of.

## Links

Lead `../backlog/B-143-http1-close-closes-an-injected-client.md` — CLOSED.
Lead `../backlog/B-224-the-wire-byte-window-test-flakes-under-the-gates-concurrency.md` — new.
Bench `../probes/P-207-what-an-orderly-close-logs-per-in-flight-call.md` — new.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [587]`.
Lesson: none. The candidate — "a count that does not scale cannot witness a per-call
claim" — is `L-12`'s subject (count the class, and put the count in the target) seen
from the measurement side, and the probe record states it.
