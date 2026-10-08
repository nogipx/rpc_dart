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

Round 740 re-measured the interop half with today's code (P-245). Reflection
list and describe, unary, server stream, a handler's NotFound, and a 1 s
`grpc-timeout` that cancels the handler's token are all clean against
`grpcurl`. The listener and socket-holding half of this record was not re-run.

## Control

Cancellation without holding the socket: the server closes the stream itself, so
the observable behaviour is set by the client.
