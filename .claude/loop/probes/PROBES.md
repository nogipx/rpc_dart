# Benches

What a bench is and when it counts as valid — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/probe.md`.

Rounds 201-205 worked with one-off probes: bench registration appeared in the
skill after them, so nothing before 206 has a record here.

- **[P-01](P-01-connection-window-debt.md)** valid (round 206), core transports —
  how much a sender gets out before the connection pool wedges
- **[P-02](P-02-http2-aborted-call-pool.md)** valid (round 207), rpc_dart_http2 —
  does an http2 connection survive a cancelled stalled call?
- **[P-03](P-03-wrapper-keeps-the-bound.md)** valid (round 209), rpc_dart_http2 —
  does a transport bound survive `RpcHttp2Server.transportWrapper`?
- **[P-04](P-04-parked-waiters-drain.md)** valid (round 211), core transports —
  does an abandoned upload leave its sender parked?
- **[P-06](P-06-handler-slots-return.md)** valid (round 214), core endpoint —
  does a handler slot come back on every teardown path?
- **[P-05](P-05-slow-consumer-is-throttled.md)** valid (round 213),
  rpc_dart_http2 — a consumer that falls behind is failed; ACCEPTED behaviour,
  see [C-19](../checked/C-19-http2-refuses-a-slow-consumer.md)
