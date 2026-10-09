---
round: 644
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: none — the witness test is the measurement; the coverage-review probe is cov_endpoint_unregister_mid_call.dart
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 644 — a contract unregistered mid-call

## Target

A coverage-review finding (round 640): the "method not registered" branches
of the responder pipeline's data and half-close paths.

## Hypothesis

A call running when its contract is unregistered gets one answer, and the
handler and the peer agree on it.

## Before

```
client-stream call, 4 messages, contract unregistered after 2
peer      status 12 Method U.upload is not registered
handler   request stream ENDED NORMALLY after 2 msgs, token cancelled=false
handler   COMMITTING upload of 2 msgs
```

## Control

No unregister: the handler gets 4 messages, the peer status 0.

## Mechanism

RPC-21, a lifecycle API driven during a call. Each data and half-close frame
looked the method up again. After the unregister the lookup found nothing, the
stream was refused UNIMPLEMENTED, and the teardown closed the handler's
request sink without an error or a cancelled token. The handler took the
truncated stream as complete; the peer was told the method did not exist. On
the half-close path the handler had every message and did the work, and a
retrying client would repeat it.

## After

The binding is looked up once per call and kept on the stream state. The
running call finishes (`n=4`, status 0); a new call after the unregister is
refused UNIMPLEMENTED.

## Canary

Looking up on every frame again: the running call fails `RpcStatusException(12)`.

## Gate

Recorded in round 645.

## Not fixed

Operator-only: no peer can trigger it.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 644]`.
Test `packages/core/rpc_dart/test/endpoint/unregistering_a_contract_leaves_its_calls_whole_test.dart`.
