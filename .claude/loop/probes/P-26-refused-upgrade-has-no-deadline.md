---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/refused_upgrade_has_no_deadline.dart
round: 276
commit: 84515602
paths: [packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-26 — is the refused-upgrade path bounded by anything?

P-23's shape aimed at the websocket server's origin gate. N sockets promise a
100000-byte body, send five bytes and hold the connection; the arms differ in
the `Origin` header and in the REQUEST SHAPE.

The request shape is load-bearing and was not obvious: dart:io hands a
CONNECTION-UPGRADE request no body at all, so an upgrade-shaped attack drains
instantly and reads as clean. `_upgradeAllowed` gates every request reaching the
server, not just upgrades, so a plain POST reaches `_refuse` just the same — and
that is the arm that holds.

## Measures

Sockets ANSWERED inside a window, counted at the client on the server's first
byte or on the close. The window must exceed the library's
`_refusalDrainBudget`: a first run used 3s against a 5s budget and read the
fixed server as still broken.

## Control

Three arms, and the first two are why the third means anything.

```
arm       origin     shape    window  answered      first answer
accepted  allowed    upgrade   3s     16 of 16      101 Switching Protocols
refused   rejected   upgrade   3s     16 of 16      403 Forbidden
plain     rejected   POST     12s      0 of 16      -              <- before
plain     rejected   POST     12s     16 of 16      closed         <- after
```

`accepted` proves the bench is not simply stalling everything; `refused` proves
the refusal path CAN answer promptly, and names dart:io's upgrade-body rule as
the reason. Without both, the `plain` row would read as "websocket servers are
slow".

> **After the fix the peer is CUT, not answered — "closed", not "403".** dart:io
> cannot flush a response on a request whose body was not consumed, so bounding
> the drain costs the status. That is the intended answer to a slowloris and the
> same trade round 272 made on the HTTP/1.1 sibling; the `refused` arm is what
> shows an ordinary refusal still gets its 403.
