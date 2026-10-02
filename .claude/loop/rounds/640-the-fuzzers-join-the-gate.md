---
round: 640
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-26
bench: P-226 — new
budget: probes 3/5, canaries 1/5
commit: yes
release: none
---

# Round 640 — the fuzzers join the gate

## Target

The owner asked for full confidence in the core. Round 639's fuzzers covered
one class, a peer's bytes, and lived in `.dart_tool/` where nothing runs them
again. Two things were open: the class fuzzing does not reach (concurrent
lifecycle under load), and keeping what was found from coming back.

## Hypothesis

A concurrent chaos run finds lifecycle defects -- a call settled twice or
never, a responder left behind -- that single-path tests do not.

## Before

No concurrent chaos harness existed, and no fuzzer ran in the gate.

## Control

The chaos harness's well-behaved calls (`ok` handlers, no caller chaos) all
return values; the server fuzzer's valid call is answered in every session.

## Mechanism

`P-226`'s harness runs 200 calls per epoch across all four shapes at once.
Handlers delay, throw, answer a status, flood, ignore their token, stop reading
or throw mid-stream; callers cancel at random times, set deadlines, abandon a
stream after a few messages, fail their own request stream; one epoch in six
tears the connection down mid-traffic. Invariants: each call settles exactly
once within 15 s, nothing reaches the zone, no responder is left after quiet,
RSS flat across epochs.

## After

```
channel pair, 10 + 60 epochs     14 000 calls   clean
in-memory, 30 epochs              6 000 calls   clean
pair + retry/breaker/limiter      3 000 calls   clean
```

Clean means: no call hung or settled twice, nothing in the zone, no responder
left, RSS flat or falling. No defect found, so the class is recorded as checked
at this sha rather than claimed absent.

Gate-sized slices now run in the ordinary gate, from fixed seeds, in a few
seconds each:

- `rpc_dart/test/fuzz/peer_bytes_decoders_fuzz_test.dart` — 3000 inputs per
  decoder; only the declared exception types.
- `rpc_dart/test/fuzz/hostile_peer_and_chaos_test.dart` — 40 hostile-peer
  sessions and 150 chaotic calls. Runs on node too, which is the first time
  either harness ran on dart2js; clean there.
- `rpc_dart_websocket/test/hostile_sockets_fuzz_test.dart` — 60 attack rounds
  against the server with compression on and off, 25 hostile-server sessions
  against the client.

## Canary

Round 639's guard removed: the websocket test fails at once, `HttpException:
More than one value for header sec-websocket-key` -- and also `...
sec-websocket-version`, a second header reaching the same unguarded call, which
the same guard covers.

## Gate

`analyze` and `format:check` green. `test:unit`: rpc_dart 1995 passed; one
red in rpc_dart_websocket, `endpoint_released_when_callback_throws_test`
(the client saw the socket close before the 101 header), with three coverage
agents running probes on the same machine. Untouched by this round; green
alone and in a full rerun of the package (279 passed).

## Not fixed

Line coverage of the core is 89.3 % (7070 of 7921). Three agents reviewed the
uncovered regions; their findings are reproduced and taken one per round from
641 on.

## Links

Bench `../probes/P-226-a-chaos-run-of-the-core.md` — new.
Lens `../lenses/RPC-26-the-gate-floor-nobody-chose.md` — `applied: [..., 640]`.
Tests `packages/core/rpc_dart/test/fuzz/peer_bytes_decoders_fuzz_test.dart`,
`packages/core/rpc_dart/test/fuzz/hostile_peer_and_chaos_test.dart`,
`packages/transport/rpc_dart_websocket/test/hostile_sockets_fuzz_test.dart`.
