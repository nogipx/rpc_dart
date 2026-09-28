---
status: open
round: — (external audit, 2026-09-28; not a round)
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

## Owner decision

—
