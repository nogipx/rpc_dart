---
round: 693
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-09
bench: none — a new test against a proxy that answers CONNECT and then stays silent, `packages/transport/rpc_dart_http2/test/a_silent_tunnel_is_bounded_test.dart`
commit: yes
release: changelog
---

# Round 693 — the proxy path is bounded

## Target

B-182's remainder: round 563 bounded the direct connects with
`connectTimeout`; the proxy path's own `Socket.connect` to the proxy and the
TLS handshake through the tunnel had no bound.

## Hypothesis

`_connectH2ViaProxy` never received `connectTimeout`; `proxyHandshakeTimeout`
covers only the CONNECT answer.

## Before

The handshake phase was not even reachable until round 692: every TLS
handshake through a proxy died in milliseconds. After 692, `secureConnect`
through a proxy that answers 200 and then says nothing, with `connectTimeout`
1 s:

```
STILL PENDING at 6s after 6009ms
```

## Mechanism

As hypothesised.

## Fix

`_connectH2ViaProxy` takes `connectTimeout`, and both callers pass theirs:

- `Socket.connect(proxyHost, proxyPort, timeout: connectTimeout)`, the form
  the direct paths use, which releases the attempt;
- `SecureSocket.secure` has no timeout parameter, so an outer `.timeout()`
  whose `onTimeout` destroys the socket -- abandoning the await alone would
  leave the handshake holding it -- and throws a `SocketException` naming the
  phase.

## After

```
SocketException: TLS handshake through the proxy did not finish within 0:00:01.000000 after 1027ms
```

## Canary

Before is the canary: the same test on the tree with round 692 and without
this change.

## The verdict questions

1. Yes: Before on the same tree.
2. Partly: the handshake phase. The connect-to-proxy phase uses the same
   `timeout:` as the measured direct paths but needs a black-holed address to
   witness, which a committed test cannot rely on.
3. Yes: how long `secureConnect` takes to fail.
4. Not zero-valued.
5. Yes, quoted.
6. One cause, two phases.
7. Not a policy question.
8. None.

## Gate

`analyze`, `format:check`, the `rpc_dart_http2` suite (290 passed),
`test:unit` green on its second run. Its first run FAILED; that output was
not kept, so which test failed is unknown.

## Not fixed

The connect-to-proxy bound is unwitnessed (above). The reconnect path
inherits both bounds through `createConnection`, not measured.

## Links

Lead `../backlog/B-182-http2-connect-has-no-timeouts.md` closed.
Lens `../lenses/RPC-09-deadline-below-write.md` -- `applied: [..., 693]`.
