---
round: 860
commit: 4150bad9
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
scope: the ready-timeout path of `RpcIsolateTransport.spawn` with a worker that never yields, 1, 2, 24 and 48 processes at once on this macOS host; not the handshake-timeout path, which none of the runs reached
---

# C-91 — a failed isolate startup exits under load

A process whose isolate spawn hit the ready deadline exits on every run,
however loaded the machine: 48 at once all exited 0, 51-53 s after launch
and 13-303 ms after their "spawn threw" line. The time goes to `dart run`
compiling and spawning, not to teardown. Bench
`../probes/P-327-a-failed-isolate-startup-under-load.md`.

## Control

`teardownStartup()` removed: the process never exits (`HUNG >90 s`).
