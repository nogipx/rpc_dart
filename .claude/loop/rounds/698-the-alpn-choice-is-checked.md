---
round: 698
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: none — by owner decision a fix by reading; no witness is reachable on this machine
commit: yes
release: changelog
---

# Round 698 — the ALPN choice is checked

## Target

B-183's last claim, decided by the owner as a fix by reading: the http2
caller offers `h2` in ALPN and never checks what the server chose, so an
HTTP/1.1-only TLS peer receives an h2 preface.

## Hypothesis

`SecureSocket.connect(..., supportedProtocols: ['h2'])` and
`SecureSocket.secure(...)` complete the handshake whatever the server picks;
`selectedProtocol` is never read.

## Before

Not measured. The witness needs a TLS server this client trusts: `secureConnect`
takes no security context, and on macOS verification goes through the system,
which ignores certificates added to the default context (round 692) -- the
handshake fails on the certificate before ALPN matters.

## Mechanism

By reading, as hypothesised: no read of `selectedProtocol` anywhere under
`rpc_dart_http2/lib`.

## Fix

`_requireH2(socket, peer)` after both TLS handshakes (direct and through a
proxy): unless `selectedProtocol` is `h2`, the socket is destroyed and a
`SocketException` names the peer and what ALPN chose (or `none`).

## After

Not measured, as Before. The `rpc_dart_http2` suite (296) passes, including
round 692's TLS-through-proxy comparison, so the check sits after a handshake
that reaches it without breaking the path.

## Canary

None: nothing reaches the check here.

## The verdict questions

1. No canary; a fix by reading, by owner decision.
2. The claim as stated, by reading.
3. Not measured.
4. -
5. -
6. One cause.
7. Yes; the owner chose to fix without a witness.
8. None.

## Gate

`analyze`, the `rpc_dart_http2` suite.

## Not fixed

The witness. On Linux, where the default context's added trust is honoured,
a TLS server without `h2` in its ALPN list would show it.

## Links

Lead `../backlog/B-183-http2-proxy-and-addressing-defects.md` closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 698]`.
