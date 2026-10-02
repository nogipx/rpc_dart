---
round: 650
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; the coverage-review probe is cov_streams_close.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 650 — a client stream closed while waiting

## Target

A coverage-review finding (round 640): `ClientStreamCaller.close()` while
`finishSending()` waits for the answer, used directly rather than through the
endpoint.

## Hypothesis

`close()` ends a call that is waiting, and the server hears of it.

## Before

```
server answers after 500 ms, no deadline
control (no close)              after 529 ms: value n=1
close() 100 ms into the wait    after 2104 ms: STILL PENDING; server not told
```

## Control

The first row.

## Mechanism

RPC-25, the "end the call" duty. `close()` cancelled the response
subscription first, so its `onDone` never ran, and nothing else completes the
response. The server-stream sibling ends its consumer's stream on close; this
one left the future pending. The endpoint path is unaffected: `call()` closes
only after the wait has settled.

## After

`close()` fails a pending response with `RpcCancelledException` and tells the
server, once (the notice now has one guarded helper, shared with the request
failure and the response timeout, and is skipped for a call that never sent
anything). The wait ends at about 100 ms and the handler's token is cancelled.

## Canary

The settle removed from `close()`: `STILL PENDING`.

## Gate

Rounds 646-650 together: `analyze` (21 packages and wasm) green, `format`
clean. `test:unit` green, exit 0, rpc_dart 2020 passed, no red in any
package. `test:web` green, exit 0, all 14 suites.

## Not fixed

Nothing known.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 650]`.
Test `packages/core/rpc_dart/test/streams/closing_a_client_stream_caller_settles_its_wait_test.dart`.
