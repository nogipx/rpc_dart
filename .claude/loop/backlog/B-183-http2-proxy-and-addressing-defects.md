---
status: closed (round 698)
round: 698
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-183 — http2 caller: proxy auth, IPv6, :authority and ALPN

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low-medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Basic auth encodes the still-percent-encoded `userInfo`; IPv6 literals are not bracketed in CONNECT; `:authority` drops a non-default port; the negotiated ALPN is never checked, so an HTTP/1.1-only TLS peer gets an h2 preface.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:323, 564-568, 677, 823`.

## Why it matters

Broken proxy credentials with special characters, broken IPv6 and virtual-host
routing, a confusing failure on ALPN mismatch.

## Witness a round would build

Proxy with password `p@ss`; IPv6 target; server on 8443 behind a host-routing
proxy.

## Fix sketch

Decode user and password; bracket IPv6; include the port; check
`selectedProtocol`.

## Progress (round 694)

FIXED, each witnessed red first: Basic auth now carries decoded credentials,
an IPv6 target is bracketed in CONNECT, `:authority` keeps a non-default port.
OPEN: the unchecked ALPN. Its witness needs a TLS server the client trusts;
`secureConnect` takes no security context and macOS ignores the default
context's added trust. `../rounds/694-the-caller-addresses-its-peer-correctly.md`.

## Outcome (round 698)

ALPN: fixed by reading, as decided -- after both TLS handshakes the caller
refuses a peer that did not choose `h2`, naming what it chose. Not witnessed.
`../rounds/698-the-alpn-choice-is-checked.md`.

## Owner decision

2026-10-07: the ALPN claim is **fixed by reading**, without a witness.
