---
status: closed (round 670)
release: none
round: 670
commit: 9fdb0440
paths: [packages/transport/rpc_dart_websocket/test/endpoint_released_when_callback_throws_test.dart, packages/transport/rpc_dart_websocket/test/a_refused_upgrade_has_a_deadline_test.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/refused_upgrade_flake.dart
reason: "bench — two different websocket tests went red in two consecutive gates (rounds 640, 645), each with an answer lost to a closed socket; both green alone and in a package rerun"
---

# B-241 — a websocket answer lost to a closed socket, under gate load only

## Seen

```
round 640 gate   endpoint_released_when_callback_throws_test
                 WebSocketChannelException: Connection closed before full header was received
round 645 gate   a_refused_upgrade_has_a_deadline_test  GUARD: a refused upgrade still gets its 403
                 1 of 8 read 'closed' instead of 'HTTP/1.1 403 Forbidden'
```

Both passed alone and in a rerun of the package (279 of 279, twice). Neither
change under test touched the websocket upgrade or refusal path.

## What is measured

The refusal alone, 100 rounds of 8 concurrent refused upgrades with a promised
body, quiet machine: `403: 800`, no `closed`.

## Hypothesis, not measured

The refused-upgrade test sends 5 body bytes after an upgrade request; dart:io
treats an upgrade request as bodiless and does not read them. Closing a socket
with unread input sends RST, and an RST that reaches the client before it
reads the 403 discards it. Load widens that window. If so, it is the test's
malformed request, not the library. The callback-throws case sends no body, so
it would need a different explanation: the 101 still in the server's buffer
when the failed setup closes the channel.

## Round 657

The probe beside rpc_dart's suite at `--concurrency=12`, 150 rounds of 8:

```
with body bytes      1200 of 1200 answered 403
without body bytes   1200 of 1200 answered 403
```

The RST hypothesis does not reproduce at this load; the two reds stay
unexplained, and the gate of rounds 646-650 was green throughout.

## What a round owes this

A frequency under the gate's own load (the probe run beside `test:unit`), and
the same probe without the body bytes. If `closed` appears only with them, the
test sends a request no real client sends and should not; if it appears
without them, the refusal path loses its answer and that is a defect.

## Outcome (round 670)

Under the gate's load the refused upgrade read `closed` 9 of 3600 times with the
body bytes and 0 of 3600 without: the test's request, not the library. The test
no longer sends a body on an upgrade. The callback-throws red did not reproduce,
0 of 1000. `../rounds/670-the-body-no-upgrade-carries.md`.

## Owner decision

—
