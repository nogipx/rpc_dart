---
round: 646
verdict: FIXED
packages: [rpc_dart]
lens: RPC-16
bench: none — the witness test is the measurement; the coverage-review probe is cov_endpoint_zero_copy_unsupported.dart
budget: probes 2/5, canaries 2/5
commit: yes
release: changelog
---

# Round 646 — a zero-copy refusal sent twice

## Target

A coverage-review finding (round 640): `_handleUnsupportedZeroCopy`, the
refusal of a codec-less method on a transport that cannot carry objects.

## Hypothesis

A refused call gets one terminal trailer, as every other refusal does since
round 467.

## Before

```
zero-copy contract on RpcChannelTransport.pair(), frames sent back to back
client-stream   [12(stream), 12(global)]
server-stream   [12(stream), 12(global)]
bidi            [12(stream)]
```

## Control

The same methods with codecs: one status per stream.

## Mechanism

RPC-16. The refusal awaited the trailer's send and recorded the stream as
closed only in its `finally`. A data or half-close frame arriving during the
await found no responder, went through `_ensureResponder` again and refused
the stream a second time. `_sendGrpcErrorAndCleanup` records the id before its
first await for exactly this reason; this path was the one refusal without it.

## After

The id is recorded synchronously at the top: one trailer on each of the three
shapes, no responder left.

## Canary

The line removed: `cs: [12, 12]`, `ss: [12, 12]`. A first version of the
witness listened on the stream's own route only and passed under the canary;
the second trailer arrives on the transport-wide route once the first has
ended the stream's, so the witness counts both.

## Gate

Rounds 646-650 together; recorded in round 650.

## Not fixed

Only a misconfiguration reaches it.

## Links

Lens `../lenses/RPC-16-check-before-await.md` — `applied: [..., 646]`.
Test `packages/core/rpc_dart/test/endpoint/a_zero_copy_refusal_is_one_trailer_test.dart`.
