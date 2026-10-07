---
round: 691
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-19
bench: none — a new test with a relay that mutes one connection, `packages/transport/rpc_dart_http2/test/a_late_probe_spares_the_new_connection_test.dart`
commit: yes
release: none
---

# Round 691 — keepalive death is UNAVAILABLE, and a late probe is harmless

## Target

B-179, two claims about the http2 caller's keepalive:

1. After a keepalive death, with no reconnect in flight, `_ensureUsable`
   throws `RpcNoConnectionException(reconnecting: false)`, which was not
   retried, where the same dead peer without keepalive gives UNAVAILABLE.
2. `onDead` does not check that the connection it probed is still the
   transport's, so a probe that times out after `reconnect()` marks the
   healthy new connection disconnected.

## Hypothesis

Claim 1 was answered by round 678 (`RpcNoConnectionException` is always
UNAVAILABLE now). Claim 2 holds by reading: `reconnect()` cancels the old
timer, but a probe already awaiting `ping()` still reaches `onDead`, which sets
`_disconnected` on the transport.

## Before

A relay in front of a real `RpcHttp2Server` that, on demand, stops passing the
server's bytes back on the FIRST connection only; keepalive 200 ms, timeout
400-800 ms.

```
a call after a keepalive death is UNAVAILABLE                       PASS (14)
a probe that times out after reconnect leaves the transport usable  PASS: 'a', 'b', then 'c' after the old timeout
```

The second check returning a status at all is the evidence the keepalive did
kill the muted connection: without it the call would hang to its 5 s timeout
and fail with a TimeoutException, not an `RpcStatusException`.

## Mechanism

Claim 1: round 678's unification. Claim 2: the race needs the old probe to
fail AFTER `reconnect()` has installed the new connection, and measured it did
not. The likely reason, not instrumented: `reconnect()` discards the old
connection first, which fails the pending `ping()` at once, so `onDead` runs
before the new connection is installed -- and `reconnect()` then clears
`_disconnected`.

## Fix

None. The two checks stay as regression tests.

## After

As Before.

## Canary

None possible for a clean result; the mute is the control that the probe
really went unanswered (claim 1's status arrives only through the keepalive).

## The verdict questions

1. A clean round; the relay's mute is the control.
2. Yes: both claims, as the lead stated them.
3. Yes: the caller's status, and whether calls keep working.
4. Not zero-valued.
5. Yes, quoted.
6. Two claims, two checks.
7. Not a policy question.
8. None.

## Gate

The two tests, the `rpc_dart_http2` suite.

## Not fixed

Claim 2's guard (`identical(connection, _connection)` in `onDead`) is not
added: nothing measured needs it, and the ordering that makes it unnecessary
is `reconnect()`'s own.

## Links

Lead `../backlog/B-179-http2-keepalive-death-status-and-a-late-callback.md` closed.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` -- `applied: [..., 691]`.
