---
round: 486
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-19
bench: P-125 — new
commit: yes
---

# Round 486 — a bad frame is not a dropped connection

## Target

B-95, the audit's second-ranked lead, taken for the same reason 485 took the
first: the rank was decided with the whole set in view. It is also the same lens
one layer up — round 485 fixed a READER of a status code, and this is a reader
of an error stream, which is the object round 353 already established as an
instance of RPC-19.

## Hypothesis

`RpcClientConnection` retires the transport on ANY error from
`incomingMessages`. Two kinds reaching that stream are documented as non-fatal —
an advisory channel error and a policy violation in lenient mode — so one of
either closes a working connection and fails every call on it. Refuted if the
proxy already filtered them, or if those errors never reach it.

## Before

```
                              transports built   the other call
advisory (a TEXT frame)            1 -> 2        errored, 3 msgs
  control: nothing sent            1 -> 1        alive,  88 msgs

lenient policy violation           1 -> 2        errored, 3 msgs
  control: nothing sent            1 -> 1        alive,  89 msgs
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/b95_advisory_retires.dart`

## Mechanism

The proxy listened with `cancelOnError: true` and treated every error as a drop.
Both layers below it had already decided otherwise: round 353 marks an advisory
error so `RpcChannelTransport` does not amplify it to the per-stream
controllers, and `_validateInbound` in lenient mode reports a violation and
keeps the connection. Both then hand the error to the one reader that reads it
as death. `IRpcAdvisoryChannelError`'s own doc says such an error "reaches the
transport's `incomingMessages`, where both endpoints log it. It just stops
there" — and behind the proxy it did not stop there.

## After

```
                              transports built   the other call
advisory (a TEXT frame)            1 -> 1        alive, 87 msgs
lenient policy violation           1 -> 1        alive, 89 msgs

real drop (peer socket closed)     1 -> 2        replacement serves a new call
strict policy violation            1 -> 2        errored -- correctly
```

**The discriminator is not the error TYPE.** Arms 2 and 4 send the identical
`RpcFrameException.policy` and differ only in `closeOnProtocolError`: in strict
mode the transport closes itself, that close arrives as `onDone`, and `onDone`
retires. So the fix declines to act on the error and lets the connection's own
ending speak.

## Canary

Two halves, two canaries, and they fail on DIFFERENT tests:

- `_isAboutOneFrame` forced to `false` — the core WITNESS fails with
  `Expected: null / Actual: RpcStatusException(14): Stream closed before the
  server completed the call`, and the websocket WITNESS with `Expected: <1> /
  Actual: <2>`, "a peer saying one non-binary thing replaced the connection".
  Both controls and both guards stay green.
- `cancelOnError` put back to `true`, predicate intact — the witnesses pass and
  the STRICT guard fails, `Expected: <2> / Actual: <1>`: the subscription is
  cancelled by the error it declined to act on, so the close that should have
  retired the transport never arrives.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS across 15 packages;
`melos run format:check` SUCCESS; `melos run license:check` 1932/1932, REUSE 3.3.

**One flake, named as unnamed.** The first `test:unit` run failed in
`rpc_dart_isolate` at load average 13.9, and the reporter output scrolled past
the failing test's name before it was captured — so it is not named, which
`config.md` asks for. What can be said: the package is `+91 All tests passed!`
run alone, and the whole gate is green on a re-run at settled load. Neither the
package nor anything it imports was touched by this round.

## Not fixed

The flapping the lead describes — a proxy keepaliving every N seconds — was not
measured, only the single event behind it.

`RpcChannelTransport` still forwards both error kinds onto `incomingMessages`,
deliberately: that is where the report is supposed to reach, and the proxy now
forwards them to its own `_msgCtl` for exactly that reason.

## Links

Lens RPC-19. Bench P-125 (new). Lead B-95 (closed). Round 353 is the decision
this one carries up a layer; round 485 is the same lens on a status code.
