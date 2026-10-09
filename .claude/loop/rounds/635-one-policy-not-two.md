---
round: 635
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-08
bench: P-216 — reused
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 635 — one policy, not two

## Target

B-227, owner's direction 1: the server hands its policy to the frame guard.

## Hypothesis

`rpcWebSocketConnections` sized the guard from its own `policy:` (default
16 MiB), so a limit raised on `RpcWebSocketServer` alone stayed at 16 MiB in the
guard.

## Before

```
server and client at 32 MiB, connections with no policy
  20 MiB request   RpcStatusException(14): WebSocket connection failed with code 1002
  same policy passed to the connections too: served
```

## Control

The same arm with the policy passed twice is served, before and after.

## Mechanism

RPC-08, a policy field honoured by one layer: two copies of one policy, and the
one the README never mentioned decided.

## After

`rpcWebSocketConnections` returns a stream that implements
`IRpcWebSocketServerPolicyTarget` (internal), and `RpcWebSocketServer.start()`
hands its policy over before listening. `policy:` on the connections is now
optional and, when given, still wins. The 20 MiB request is served with the
policy on the server alone.

The first version adopted the server's policy exactly, and
`oversized_message_is_refused_test.dart` went red three times: a whole 8 MiB
message against a 1 MiB server used to pass the 16 MiB guard and be refused by
the multiplexer with 4400 and a reason (not retried); with the guard at 1 MiB it
was a destroyed socket, which the peer reads as a retryable drop. So an adopted
policy only RAISES the ceiling above the default: above 16 MiB the guard follows
the server, below it the multiplexer still answers. The residency bound is round
611's.

## Canary

`adoptServerPolicy` made a no-op: the witness fails with `RpcStatusException(14):
WebSocket connection failed with code 1002`.

## Gate

`analyze` and `format` on rpc_dart_websocket green, its 274 tests green. The
first `test:unit` was red on two core timing tests under load (`Large data
encoding took: 283ms` where it reads ~15): `the_window_counts_wire_bytes`'
CONTROL and `fast_cbor_encoder_test`'s float average, whose cold first run read
162 ms. Neither touches this change; the rerun was green (exit 0). The float test
asserted an AVERAGE that carries the cold run, so it now asserts the minimum only
(B-224's lesson), in its own commit.

## Not fixed

A guard refusal is still a destroyed socket, not a close frame (round 611); it
is reached now only past the larger of 16 MiB and the server's limit.

## Links

Lead `../backlog/B-227-the-connections-policy-is-a-second-copy.md` — closed.
Bench `../probes/P-216-an-unfinished-websocket-message.md` — reused.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [..., 635]`.
Test `packages/transport/rpc_dart_websocket/test/the_server_policy_reaches_the_frame_guard_test.dart`.
