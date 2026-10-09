---
round: 692
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: none — a new test against a self-signed TLS server behind an in-test CONNECT proxy, `packages/transport/rpc_dart_http2/test/tls_through_a_proxy_test.dart`
commit: yes
release: changelog
severity: S1
---

# Round 692 — TLS through a proxy reaches the server

## Target

Found while building B-182's witness: `secureConnect` through an HTTP CONNECT
proxy. `proxy_connect_limits_test.dart` says this path was never exercised
end to end ("reaching it needs a working TLS endpoint").

## Hypothesis

A proxy that answered 200 and then said nothing failed the TLS handshake in
22 ms with `HandshakeException: Connection terminated during handshake` -- the
client side ended it, since the proxy closed nothing. `_connectH2ViaProxy`
cancels its socket subscription before `SecureSocket.secure`, and
`SecureSocket.secure`'s documentation asks for the subscription to be PAUSED.

## Before

A real TLS `RpcHttp2Server` (self-signed, `localhost`), and a working CONNECT
proxy in front of it. The same `secureConnect` direct and through the proxy:

```
DIRECT   HandshakeException: ... CERTIFICATE_VERIFY_FAILED
PROXIED  HandshakeException: Connection terminated during handshake
```

The direct connection reaches the server and fails certificate verification,
as it must for a self-signed certificate on macOS. Through the proxy the
handshake never reached the server: `secureConnect` through any proxy could
not work.

## Mechanism

As hypothesised: cancelling the subscription closes the socket's read side.

## Fix

`sub.pause()` instead of `await sub.cancel()` before `SecureSocket.secure`.

## After

```
DIRECT   certificate rejected
PROXIED  certificate rejected
```

The test asserts the proxied outcome equals the direct one, and that the
direct one is 'served' or 'certificate rejected' -- the certificate is added
to the default context, which some platforms honour and macOS does not, so a
served call cannot be demanded everywhere.

## Canary

`cancel` restored: `Expected: 'certificate rejected'  Actual: 'HandshakeException:
Connection terminated during handshake'`. Restored: green.

## The verdict questions

1. Yes: one canary; the direct connection is the control.
2. Yes: the path, end to end, against a real TLS server.
3. Partly: how far the handshake gets. A served call through the proxy is not
   shown on this platform.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Not a policy question.
8. None.

## Gate

The test, `analyze` of the package, the `rpc_dart_http2` suite (289 passed).

## Not fixed

A served call over TLS through a proxy is shown only up to certificate
verification on macOS. `secureConnect` takes no security context, so a
caller cannot trust a private CA through it; a separate question.

## Links

No lead: found during B-182's round. Lens
`../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 692]`.
