---
round: 641
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; the coverage-review probe is cov_streams_sendfail.dart
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
---

# Round 641 — a request that cannot be sent

## Target

Round 640 left line coverage of the core at 89.3 %, and three agents read the
uncovered regions with probes. This is the most serious of their findings: the
send-failure branch of `CallProcessor._transmitRequest`.

## Hypothesis

A request that fails to go out mid-stream is reported to the server the way a
failed request stream is.

## Before

```
requests a, b, bad, c; the request codec throws on "bad"
client-stream caller   ERR Bad state: cannot serialize "bad"
bidi caller            ERR Bad state: cannot serialize "bad"
server handlers        CLEAN END after [a, b]   -> client-stream answers OK, committed:[a, b]
```

## Control

The producer throwing at the same position: both handlers see
`RpcCancelledException` after `[a, b]`. A working codec: `CLEAN END after
[a, b, bad, c]`.

## Mechanism

RPC-25, read as a duty: when the request side dies, tell the peer. The catch
put the error on the response stream and closed the request controller, and
that controller's `onDone` is the ordinary half-close. `send` never threw,
because it awaits a sequence that had already swallowed the error, so
neither `ClientStreamCaller`'s abort nor the bidi pump's `onSourceFailed` ran.
The server read the half-close as "these are all the requests".

## After

The catch marks the call, sends the cancellation notice (a reset where the
transport has one), and `onDone` no longer half-closes a marked call.

```
server handlers        ERROR after [a, b]: RpcCancelledException: A request could not be sent
```

## Canary

The two lines removed: both shapes of the witness fail with `clean [a, b]`.

## Gate

Run once for rounds 641-645: `analyze` (21 packages and wasm) and
`format:check` green, `test:unit` recorded in round 645.

## Not fixed

Server-stream and unary send their single request before half-closing, so a
codec failure there is already refused (INVALID_ARGUMENT); not touched.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 641]`.
Test `packages/core/rpc_dart/test/streams/a_request_that_cannot_be_sent_is_not_a_clean_end_test.dart`.
