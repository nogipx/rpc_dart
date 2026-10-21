---
file: packages/test/rpc_dart_conformance/.dart_tool/probe/r890_siblings/probe.dart
round: 890
commit: b3350b20
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/transport/rpc_dart_socket/lib/src/rpc_socket_connect.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
promoted: no — the socket and http2 halves are what the core witness `a_stop_ends_the_attempt_in_flight_test.dart` already covers with a transport that is never ready; the TLS arm is a lead (B-309), not a fix
---

# P-342 — r890 siblings dispose mid connect

## Measures

The P-341 measurement for the socket and http2 callers, plain constructor (they
take no token), silent listener. With the core readiness race switched off:
socket and http2 29808 / 29802 ms with default timeouts, still open at 40 s
with none. With it: 0-12 ms. `MODE=tls`: http2 `secureConnect` against the
same silent listener is still open at 40 s even with default timeouts (one
run, with the fix in place; the TLS handshake is inside the factory, which the
readiness race does not reach). B-309.

## Control

The before/after pair itself: the only change between the two runs is the
readiness race in `client_connection.dart`, switched in place.
