---
round: 903
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-21
bench: none — the witnesses are the extended test and a probe file named below
commit: yes
release: none
---

# Round 903 — a peer endpoint driven twice

## Target

RPC-21 on the code the API review rewrote most: since 33421a73 a peer
endpoint IS a responder endpoint and starts through the responder's
`start()`, passing its parity filter as a getter that returns a tear-off. The
existing lifecycle tests (`second_start_is_not_a_warning_test`,
`double_start_no_duplicate_test`, `a_second_close_waits_for_the_first_test`)
built only `RpcResponderEndpoint`. Taken over the ranked lenses because the
code is a day old and none of them has seen it.

## Hypothesis

At stake, S2: a peer's second `start()` passes a NEW filter object, so the
"different messageFilter" branch warns on every connection, or a second
subscription delivers every frame twice. Also driven out of order on both
endpoints: two concurrent closes, close before start, start after close.
Fails if any of these warns, double-delivers, throws, hangs or disposes a
contract twice.

## Before

```
second_start_is_not_a_warning_test, responder and peer arms   +8, all green
  (no warning on the ordinary second start; the different-filter warning
   still fires; served once after a redundant start)

probe r903, both arms identical:
  two concurrent closes        contract disposed 1 time
  close before start           completes, isActive false
  start after close            no throw; a call fails RpcClosedException;
                               metrics.isListening reads true
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/r903_lifecycle_test.dart`

## Mechanism

None for S1/S2. Two tear-offs of one instance method on one receiver are
`==` in Dart, so the filter comparison holds; the listening claim is taken
before the first await, so a second start returns.

## After

Unchanged code. `second_start_is_not_a_warning_test` now runs every case on
both a responder and a peer endpoint.

## Canary

n/a for a CLEAN round; the extended test is the responder's existing
witness, now with a peer arm.

## Gate

`second_start_is_not_a_warning_test`: +8. `analyze`, `format:check`,
`license:check`: green. `test:unit:quiet`: rpc_dart +2415 and nine other
packages green; seven did not start, because pub.dev was unreachable and
`dart test` checks it first. Those seven, run through the prebuilt runner
snapshot instead: websocket +309, isolate +108, socket +41, log +104,
opentelemetry +20, data +62, notify +73.

## Not fixed

`start()` after `close()` re-subscribes to the closed transport and leaves
`collectEndpointMetrics().isListening` true on a closed endpoint, on both
arms. S3 at most (a diagnostic that lies; every call still fails
`RpcClosedException`); put to the owner rather than taken.

## Links

RPC-21.
