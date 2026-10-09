---
round: 603
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the observable is the count of error records per call, read by the counting LogController the round-516 test already uses
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
severity: S3
---

# Round 603 — every streaming answer was an incident

## Target

B-124's flooding half, which the lead itself says "needs no peer-reachability
argument": round 516 stopped unary logging an application status at `error`, and
the three streaming shapes were never varied. Counted before the fix, every site.

## Hypothesis

A server-stream, client-stream or bidi handler answering NOT_FOUND produces `error`
records on both sides, the way unary did before round 516.

## Before

```
                 caller                              responder
server-stream    2  ended with error / call failed   2  handling failed / sending error
client-stream    3  status / finish sending / call   2  handling failed / sending error
bidi             0                                   2  error in bidi handler / sending error
```

One NOT_FOUND call each, records counted by overriding `LogController.add`.
INTERNAL and a status-less throw are the controls that must stay loud.

## Mechanism

Nine sites logged any non-OK status or any caught error at `error` without asking
whether it was an answer or a fault. Round 516 introduced `RpcStatus.isFault` for
exactly this and applied it to unary only.

## After

All nine consult it: the three that hold a status code call `RpcStatus.isFault`
and log a non-fault at `debug` (guarded); the six that hold a caught error call
the new `RpcStatus.isFaultError`, which treats a throw with no status as a fault.
Every streaming NOT_FOUND arm reads zero; every INTERNAL arm still reaches `error`.

## Canary

Two switches, each bringing back exactly its own sites by name:
- `isFaultError` forced true: `Server stream call failed`, `Request handling
  failed`, `Failed to finish sending`, `Client stream call failed`, `Client stream
  handling failed`, `Error in bidi handler` — the six catch sites.
- `isFault` forced true with `isFaultError` classifying on its own: `Server stream
  ended with error`, `Received error status code`, `Sending error to client` — the
  three status sites.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages, rpc_dart
+1903, websocket +250, http2 +275), `melos run format:check`, `melos run
license:check` — green.

## Not fixed

- B-124's per-call peer warnings in the responder (stream ceiling, handler
  ceiling, pre-method refusal, unknown-stream no-op, endpoint-not-started) still
  fire once per occurrence — the next round.
- A genuine fault is still logged twice on a caller (round 516's open half): the
  two records carry different information and choosing one is a decision.

## Links

Lead `../backlog/B-124-peer-triggered-warnings-fire-per-frame.md` — open, narrowed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [603]`.
Test `packages/core/rpc_dart/test/logger/an_application_status_is_not_an_incident_test.dart`.
