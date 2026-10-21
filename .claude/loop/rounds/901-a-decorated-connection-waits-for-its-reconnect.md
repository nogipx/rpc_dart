---
round: 901
verdict: FIXED
packages: [rpc_dart]
lens: RPC-04
bench: none — the witness is the regression test itself, two arms in one file
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: breaking
---

# Round 901 — a decorated connection waits for its reconnect

## Target

Item 8 of the owner's API review (`IRpcTransport`, 21 members over three
layers). Reading it for the review turned up one capability that is not a
member: `RpcRetryInterceptor` and `registerServiceContract` test
`transport is IRpcReconnectOutcome`, an interface not exported. RPC-04 is
exactly that class -- a capability a wrapper hides.

## Hypothesis

A transport decorator over `RpcClientConnection.transport`, written as
`IRpcTransport`'s own doc says (`implements`, forward every member), hides
the reconnect capability, so a retried UNAVAILABLE call does not wait for
the reconnect and fails. Fails if the decorated call succeeds like the bare
one.

## Before

```
arm           runs  result
bare (CONTROL)  3   response 'hi'
decorated       3   RpcStatusException(14): RpcClientConnection is
                    reconnecting and has no connection; retry.
```

Setup: the connection drops, the server is back at once, the connection
reconnects after its 100 ms backoff; `RpcRetryInterceptor` with a 10 ms
backoff and 3 attempts.

Probe: `packages/core/rpc_dart/test/resilience/a_decorated_connection_still_waits_for_its_reconnect_test.dart`

## Mechanism

RPC-04. The retry waited for the reconnect only when the endpoint's
transport WAS the connection's proxy, by type. The decorator cannot
implement an interface that is not exported, so all three attempts landed on
the dead connection within ~20 ms. Registration took the same test, so a
zero-copy contract over the decorator threw at registration instead of being
answered UNIMPLEMENTED per call (read from the code, not probed).

## After

`IRpcTransport.reconnectOutcome`, a nullable member with a `null` default
like `flowCredit` and `connectionBuffer`; `IRpcReconnectOutcome` exported
from `transport.dart`; the proxy returns itself; the retry and the
registration read the member. A decorator that `implements IRpcTransport`
fails to compile until it forwards it -- 15 test decorators did. The probe:
both arms green, 3 of 3.

## Canary

The retry's check put back to `transport is IRpcReconnectOutcome`: the
decorated arm red with the same `RpcStatusException(14)`, CONTROL green.
Restored: both green.

## Gate

`analyze`, `test:unit:quiet --no-select`, `format:check`, `license:check`,
`check:skills`, `api:check` after `api:update`, `test:web --no-select`
(+2342 ~1): green.

## Siblings

- caller: fixed here -- the retry interceptor is the caller side.
- responder: fixed here -- `registerServiceContract` reads the member.
- channel, http, http2, socket, websocket, isolate, wasm transports: n/a --
  none reconnects; only `RpcClientConnection`'s proxy has the capability, and
  every transport reaches it through the same member now.
- `IRpcSerializable`, `IRpcAdvisoryChannelError`: n/a -- markers on values
  and errors, which nothing decorates.
- (not a group member) websocket server's connections stream: deferred --
  B-312, the same `is` shape on `IRpcWebSocketServerPolicyTarget`, not
  measured.

## Not fixed

The registration path over a decorator was read from the code, not probed;
it reads the same member now. B-312 is left open. The 4 test fakes that
implemented `IRpcReconnectOutcome` directly were given
`reconnectOutcome => this`, or they would have gone silently unchecked.

## Links

RPC-04, B-312.
