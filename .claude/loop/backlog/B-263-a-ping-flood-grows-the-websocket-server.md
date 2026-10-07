---
status: closed (round 713)
round: 713
commit: 0f167865
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart]
probe: .dart_tool/probe/audit_ws/ping_attacker.dart
reason: "measured — found by the websocket audit after round 710"
---

# B-263 — a ping flood grows the websocket server

## Seen

One upgraded connection that floods 125-byte pings and never reads, with an
unsolicited pong every 0.5 s so keepalive never fires; server and attacker in
separate processes, default `RpcWebSocketServer`:

```
attacker sent 3433 MiB of pings in 10s
t=18s server rssDelta=3145 MiB opened=1 closed=0
```

dart:io answers each ping with a pong on an unbounded write queue. No rpc_dart
limit sees control frames.

## Owner decision

None needed: unauthenticated memory exhaustion on defaults.
