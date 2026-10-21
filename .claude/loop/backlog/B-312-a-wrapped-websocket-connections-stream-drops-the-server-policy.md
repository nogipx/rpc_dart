---
status: open
round: 901
commit: 76aa894d
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: none
reason: risk — a suspicion from round 901's sibling sweep, not measured: the server hands its policy to the connections stream only through an `is` check
rank: 10
---

# B-312 — a wrapped websocket connections stream drops the server policy

`RpcWebSocketServer.start` gives its `RpcSecurityPolicy` to the connections
stream only when the stream `is IRpcWebSocketServerPolicyTarget`, the source
`rpcWebSocketConnections` returns. That source's frame guard sizes its
ceiling from the policy. An application that wraps the stream before handing
it over -- `.where(...)` to filter by origin, `.map(...)` to log -- passes a
plain `Stream`, the check fails, and the guard keeps whatever ceiling it had.

Round 901 fixed the same shape on `IRpcTransport` (RPC-04): a capability
found with `is` that a wrapper cannot carry.

Unknown: what the guard's ceiling is without the server's policy, and so
whether a wrapped stream refuses messages the policy allows, or admits ones
it refuses before the transport's own check.

## Next step

Probe: a server with a raised and a lowered `maxMessageBytes`, its connections
stream passed bare and passed through `.where((_) => true)`; send a message
between the default ceiling and the policy's on each arm.

## Owner decision

—
