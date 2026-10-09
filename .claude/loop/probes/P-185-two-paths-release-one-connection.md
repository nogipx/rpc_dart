---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b192_accept_path_address_read.dart
round: 562
commit: 90a46e39
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
status: valid
---

# P-185 — two paths release one connection, and one address read that was said to be fatal

## Why it exists

B-192 claims `onConnectionClosed` fires twice for a connection the preface deadline reclaims, and that
an unguarded `socket.remotePort` in the accept path lets a connect-and-reset peer end the server
process. Confidence **high**, nothing run.

The second claim cites the class's own comment as support, which is the kind of agreement rule one says
to distrust: the comment is about reading on CLOSE and the code reads on ACCEPT.

## The harness

Three arms, because the two claims need different instruments and the second needs two.

**Counting**: one connection, `prefaceTimeout` 100 ms, a counter in `onConnectionOpened` and
`onConnectionClosed`, driven two ways — silent until the deadline reclaims it, and speaking HTTP/2 then
closing politely.

**The reset loop**: 200 x connect-then-`destroy()` inside `runZonedGuarded`, counting escapes, **then a
real call**. The call is the arm that matters — "still running" is a flag an isolate about to die still
reports, so the question is whether the server still answers.

**The address read in three states**, which is the positive control for the mechanism itself: just
accepted, peer reset but our end still open, and after our own `destroy()`.

No logger is attached anywhere: the address read is unconditional while only being USED under
`isDebug`, so the exposure must not depend on the log level.

## The numbers (round 562)

```
  silent, preface deadline    opened=1  closed=2   ->  closed=1 after the fix
  speaks h2, closes politely  opened=1  closed=1

  200 x connect+RST   escaped=0   then a real call -> ok:x
  200 x polite close  escaped=0   then a real call -> ok:x

  just accepted             127.0.0.1:63895
  peer reset, still open    127.0.0.1:63895
  after our own destroy()   THREW SocketException: Socket has been closed
```

## Measures

Callback counts per connection, zone escapes, and whether the server still serves. Then the address
read's outcome by socket state — the only thing here that is about a mechanism rather than a count.

## Control

**The polite close** is the control for the counting arm: without it, `closed=1` could mean the
callback had stopped firing rather than firing once.

**The three address states are the control for the refutation**, and they are what makes it a
refutation rather than an absence. Two clean reset rows mean "the accept path is safe" or "this rig
never produced the failing state"; the third row shows the state that DOES throw and that only our own
close produces it.

`opened=1` in every row is a third control: the guard added for the close half must not have been
needed for the open half, and was not.

## What it establishes, and what it does not

Establishes that two paths released one connection and the user's callback saw both, and that the
accept-path address read cannot be in the throwing state — the throwing state needs our end closed, and
`notifyWithoutDying` already covers the close path where that happens.

Does NOT make the refutation platform-general. The reset loop is 200 cycles on one OS; what carries the
claim is the state rows, not the loop.

Does NOT cover B-192's other four items: serial endpoint close on `stop()`, `start()` re-entrancy
(partly addressed in round 560), `createWithContracts` dropping options, and the comment the lead calls
probably false.

## Reading

rpc_dart_http2 — three instruments for two claims: callback counts per
connection, a 200x connect-and-RST loop inside a guarded zone **followed by a
real call** ("still running" is a flag a dying isolate still reports), and the
address read in three socket states. **That third arm is the positive control
that turns an absence into a refutation** — `just accepted` and `peer reset,
still open` both answer, `after our own destroy()` throws, so the throwing
state needs OUR end closed and the accept path cannot be in it. No logger
attached anywhere, because the read is unconditional while only being used
under `isDebug`. `opened=1` in every row is a third control: the guard added
for the close half was never needed for the open half.
