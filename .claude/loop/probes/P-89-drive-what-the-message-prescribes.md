---
file: packages/core/rpc_dart_framework/.dart_tool/probe/create_a_new_app_to_restart.dart
round: 404
commit: 246c5e74
paths: [packages/core/rpc_dart_framework/lib/src/rpc_app.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-89 — do what the error message says, and nothing else

## Why it exists

Round 401 minted the detector: a `throw` whose message PRESCRIBES an action is
an API surface nothing type-checks, read by someone already in trouble. It found
one that could not work. L-12 then applies — count the class before concluding
anything from one instance.

## Measures

Per prescriptive site: reach the state the message describes, do exactly what
the sentence says and nothing more, and report whether it worked.

Three files, because the sites live in three packages and one probe cannot
import all three. The frontmatter names the framework one; the other two are

```
packages/transport/rpc_dart_websocket/.dart_tool/probe/call_reconnect_it_says.dart
packages/transport/rpc_dart_http2/.dart_tool/probe/call_reconnect_it_says.dart
```

and they are deliberately the same file twice over, one per transport, because
the two copies of the sentence are what RPC-25 says to read side by side.

## Control

Each arm carries the pre-state — `first call: served`, `first started, stopped`
— so an arm that never reached the state it names cannot read as a clean one.
That column is P-84's `grpc-status` lesson in a different currency.

And the two-claim messages are split into two arms, because a sentence with an
`and` in it can be half true: "call reconnect()" and "a failed reconnect leaves
the transport recoverable, not closed" are separate assertions, so the
server-still-gone arm goes on to try a LATER reconnect — "recoverable" buys
nothing if it only means `isClosed == false`.

## The numbers (round 404)

```
"create a new RpcApp to restart"
  after stop, same modules   restart ok   server starts 2   module: starts 2 stops 2
  after stop, new modules    restart ok   server starts 2
  after a FAILED start       restart ok   server starts 2

"call reconnect()"                refused with          reconnect    isClosed  after
  websocket, server back up       StateError            healthy      false     served
  websocket, server still gone    StateError            unhealthy    false     LATER healthy -> served
  http2,     server back up       RpcStatusException    healthy      false     served
  http2,     server still gone    RpcStatusException    unhealthy    false     LATER healthy -> served
```

## What it establishes, and what it does not

Establishes: three of the four prescriptions driven so far are correct,
including both halves of the two-claim one on both transports. The fourth is
round 401's, which was not.

It also shows a DRIFT the arms were not looking for: the same disconnected state
refuses with `StateError` on websocket and `RpcStatusException` on http2 — one
sentence, two copies, two types a caller would have to catch differently.
B-08's family, closed in round 201 for the CLOSED state; this is the
DISCONNECTED one and nothing has measured it.

Does not drive the other ~16 prescriptive sites; the class count is in round
404's record.
