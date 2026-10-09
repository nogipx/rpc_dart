---
round: 485
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-19
bench: P-124 — new
commit: yes
severity: S2
---

# Round 485 — UNAVAILABLE is about the call, so ask the transport about the connection

## Target

The backlog is 101 leads from one external audit, none of them measured — the
container that filed them had no Dart SDK, so every one says `probe: none` and
names a witness a round owes it. The audit ranked them itself: B-94..B-107 are
the damage-class leaders, and B-94 is first.

Took the first, because the rank is a judgement already made with the whole set
in view and re-deriving it costs a round. Its damage class is also the widest
here: one call's ordinary failure failing every OTHER call on the connection.

The lens is RPC-19 — one signal carrying two lifecycle meanings. Round 353
already extended it from a flag to an error stream; this is the same shape one
level up, on a STATUS CODE, and `resilience/**` is in its `paths:`.

## Hypothesis

`_reconnectIfConnectionIsGone` checks nothing about the connection. If any
`RpcStatusException(unavailable)` reaches it, a websocket's `reconnect()` closes
the live socket, so a second call on that socket dies of the first one's
failure. It would be refuted if the interceptor never reached `reconnect()` for
an application-thrown status, or if the websocket wrapper kept the old socket
alive for calls already on it.

## Before

```
                              sockets  A                B
case    unavailable              2     errored, 4 msgs  RpcStatusException
control resourceExhausted        1     alive,  30 msgs  RpcStatusException
```

Call A is a server stream running throughout; call B is one unary call whose
HANDLER throws. The arms differ in that status and nothing else.

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/b94_retry_reconnect.dart`

## Mechanism

UNAVAILABLE is what the framework puts on a lost connection, and it is also what
a handler throws when a downstream is down, what a draining server answers, and
what core synthesises for one truncated stream. The interceptor read the status
as evidence about the CONNECTION when it is only evidence about the CALL, and
`RpcWebSocketCallerTransport.reconnect()` is unconditional: cancel the forwarder,
close `_inner`, build a new socket. Every other call on the old socket is
answered by that close — and each of those answers is itself UNAVAILABLE, so
concurrent retrying calls feed the same mechanism again.

## After

```
                              sockets  A                B
case    unavailable              1     alive,  30 msgs  RpcStatusException
control resourceExhausted        1     alive,  30 msgs  RpcStatusException

dropped (the path really died)   2     recovered: slow:x
```

The case arm now reads what the control always did. The third arm is the
capability B-61 added and is the reason this is not a revert: a call truncated by
a socket that really died still reconnects and still passes.

## Canary

Two, because the fix has two halves — do not reconnect on a live connection, and
DO reconnect on a dead one.

- `if (1 < 0 && (await transport.health()).isHealthy) return;` — the WITNESS
  failed with `Expected: <1> Actual: <2>`, "one call failed; the connection
  under every other call was fine, and reconnecting it opened a second socket".
  The CONTROL and the GUARD stayed green under it, so the test isolates the new
  defect.
- `if (1 > 0) return;` at the top of `_reconnectIfConnectionIsGone`, removing
  the reconnect altogether — the dropped arm falls to
  `sockets=1  result=RpcNoConnectionException`, so the guard arm is
  load-bearing rather than decorative.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS (rpc_dart `+1688 ~1`, rpc_dart_http2
`+247`, rpc_dart_websocket `+195`, all 15 packages);
`melos run format:check` SUCCESS; `melos run license:check` — 1928/1928 files,
REUSE 3.3 compliant.

`loop.py lint` was RED before this round touched anything, at **102 errors**, and
101 of them were one shape: the audit intake wrote `round: — (external audit,
2026-09-28; not a round)` into every lead it filed, which the schema refuses.
Repaired in all 100 still open — `— (not re-measured)`, the value the spec names
for a record nobody has measured — because the alternative is that no round for
the next hundred can report a green lint, and nothing in those lines is lost
(every lead's `reason:` already carries the intake and its date).

**One error is left and it is not mine to clear**: `8253fe8a` and `93a37821`
both touch only `.claude/loop/`, which the sprawl check wants squashed. Both are
already on `origin/main`, and rewriting pushed history is the owner's call.

One existing test failed on the fix and was repaired rather than weakened:
`retry_reconnects_before_trying_again_test.dart`'s `_FlakyTransport.health()`
answered `healthy` unconditionally while its own `up` was false. The situation it
measures — the connection is gone — is unchanged; the fake now has to say so in
the one place the code reads, which no transport this library ships gets wrong.

## Not fixed

The cascade the lead also names — N concurrent retrying calls turning into
serial reconnects — was not measured. One failing call settles the mechanism and
the fix removes the trigger for any number of them.

`RpcWebSocketCallerTransport.reconnect()` itself is untouched: closing the socket
is what a reconnect IS. The defect was asking for one.

## Links

Lens RPC-19. Bench P-124 (new). Lead B-94 (closed). The capability the guard arm
protects is B-61's, pinned by P-114's sibling
`retry_reconnects_before_trying_again_test.dart`.
