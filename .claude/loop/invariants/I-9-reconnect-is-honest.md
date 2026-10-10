---
across: transport
test: packages/test/rpc_dart_conformance/test/i9_reconnect_is_honest_test.dart
severity: S1
---

# I-9 — reconnect is honest

## Statement

A reconnecting client is Online again after the server restarts, and is never
Online before the peer has proven it speaks the protocol.

The second half does not apply to http (no connection exists before a
request) or to a bare channel (no handshake); members built on a channel
prove readiness at their own layer. B-282.
