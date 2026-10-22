---
status: open
round: 905
commit: b5e7f667
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart]
probe: none
reason: risk — read from the code in round 905, not measured: RpcIsolateTransport.spawn is the one async transport open left without a cancellationToken, so a dispose mid-spawn waits for the worker's ready or startupTimeout (30 s)
rank: 5
---

# B-315 — an isolate spawn takes no cancellation token

After round 905 the websocket, socket and http2 callers all end their open on
the token `RpcClientConnection` hands its factory. `RpcIsolateTransport.spawn`
takes none. Its wait is on the process's own worker, bounded by
`startupTimeout`, so the cost is at most that long and only when the worker's
entrypoint is slow or never signals ready.

Unknown: whether anyone puts `spawn` behind `RpcClientConnection`, and what a
dispose mid-spawn holds (the isolate, its ports) until the timeout.

## Next step

A worker entrypoint that never signals ready, `RpcClientConnection` over
`spawn`, dispose at 200 ms: when is the isolate gone (`Isolate.addOnExitListener`)?
Control: the same with a ready worker.

## Owner decision

—
