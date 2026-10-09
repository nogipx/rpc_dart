---
round: 605
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the observable is the count of caller error records per failed call, read by the counting LogController in the test
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
severity: S3
---

# Round 605 — one failure, one record

## Target

B-124's last item, decided by the owner this session: a caller logged a genuine
fault twice. The owner chose the call's own catch record (error, method path,
stack) as the one that stays. Applied to every shape, because the measurement
showed they disagreed.

## Hypothesis

Each caller shape produces exactly one error record for a genuine fault.

## Before

```
genuine INTERNAL, caller records
unary     2   trailer site + call catch
server    2   trailer site + call catch
client    3   trailer site + finishSending catch + call catch
bidi      0   none at all: the fault was silent on the caller
```

Test: `test/logger/an_application_status_is_not_an_incident_test.dart`, the
INTERNAL guards now asserting `hasLength(1)` on the caller.

## Mechanism

Status sites, an inner catch and the call-level catch each logged on their own;
the bidi bridge in `caller_pipeline.dart` handed the error to the consumer without
logging it anywhere.

## After

```
unary 1   server 1   client 1   bidi 1     (NOT_FOUND: 0 on every shape)
```

- The unary, server-stream and client-stream status sites log at `debug` for every
  status.
- `ClientStreamCaller.finishSending`'s catch logs at `debug` and rethrows to the
  call.
- The bidi bridge's `onError` logs a fault once (`Bidirectional call /S/M failed`).
- `BidirectionalStreamCaller.payloadResponses`, used directly without an endpoint
  and so the only record on that path, logs a fault at `error` and an answer at
  `debug`.

## Canary

The before-table is this code with each change absent, and each guard failed with
its own count: unary and server `has length of <2>`, client `<3>`, bidi `<0>`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages, rpc_dart
+1908, websocket +250), `melos run format:check`, `melos run license:check` —
green.

## Not fixed

Nothing left in B-124 except the two responder sites round 515 found unreachable.

## Links

Lead `../backlog/B-124-peer-triggered-warnings-fire-per-frame.md` — closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [605]`.
