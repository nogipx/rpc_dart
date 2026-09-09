---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_http2/lib/**]
scope: [http2 against grpcurl]
---

# C-15 — A real gRPC client: listener resilience and cancellation

Rounds: 54 (the listener), 55 (cancellation). Driver: grpcurl.

Sockets held open and client-side cancellation are clean. `grpcurl` and `go` are
installed on this machine, so the battery is reproducible.

## Control

Cancellation without holding the socket: the server closes the stream itself, so
the observable behaviour is set by the client.
