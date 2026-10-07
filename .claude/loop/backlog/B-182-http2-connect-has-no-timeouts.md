---
status: closed (round 693)
round: 693
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-182 — http2 caller: no timeout on connect, TLS handshake or connect-to-proxy

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`SecureSocket.connect`, `Socket.connect`, the proxy `Socket.connect` and `SecureSocket.secure` have no timeout; `proxyHandshakeTimeout` covers only the CONNECT response, and the comment at `:470-474` names this exact risk; single-flight reconnect makes every caller join a hung attempt.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:320-324, 440, 470-474, 556, 675`.

## Why it matters

An application that hangs at startup against a black-holed host.

## Witness a round would build

Connect to a black-holed address.

## Fix sketch

One connect timeout covering socket, TLS and proxy phases.

## Outcome (round 563) — CONFIRMED, and the direct paths are bounded

`../rounds/563-the-bound-the-comment-described-and-did-not-provide.md`. Bench
`../probes/P-186-what-bounds-a-connect-into-a-hole.md`.

```
  refused, bound at 2s        OSError after 10ms
  black-holed, bound at 2s    OSError after 1730ms
  black-holed, bound OFF      STILL PENDING at the probe cap of 8s
```

`198.51.100.1` is TEST-NET-2, reserved and not routed, so its SYN is dropped rather than refused — the
difference between the first row and the other two. A prompt failure is 10 ms; a dropped SYN had no
bound of ours at all.

**Fixed with a `connectTimeout` on `connect` and `secureConnect`, defaulting to 30 s** — the number its
proxy sibling already uses, since the two bound phases of one operation. **Passed as `timeout:` to
dart:io rather than wrapped in `.timeout()`**: a wrapper abandons the future while the connect carries
on, leaving a socket nobody holds and nobody closes. On the TLS path the one argument covers the
handshake too. Null restores the old OS-decides behaviour.

**The bound-OFF row is the canary and lives in the probe**, because without it `1730ms` could be the
network answering rather than the timeout firing.

**No test was added to the tree, deliberately.** The witness needs an address whose SYN is DROPPED, and
whether a network drops or refuses `198.51.100.1` is not something this repository controls — a firewall
that refuses it turns the black-hole rows into the refused row and the test fails for an unrelated
reason. That is the B-196 class.

Still open: the proxy path's own `Socket.connect` inside `_connectH2ViaProxy`, which needs the same
argument threaded through. The reconnect path inherits the bound by construction (`createConnection` is
also the `connectionFactory`) but was not measured. And 30 s matches the sibling rather than any
measurement of what a slow link needs.

## Outcome (round 693)

FIXED. The proxy path now takes `connectTimeout` for reaching the proxy and
for the TLS handshake through the tunnel. Witnessed on the handshake: a silent
tunnel was still pending at 6 s, now fails in 1027 ms with a 1 s bound. The
handshake was not reachable before round 692, which found that every TLS
handshake through a proxy died at once.
`../rounds/693-the-proxy-path-is-bounded.md`.

## Owner decision

—
