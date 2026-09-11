---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/terminate_rejects_into_the_zone.dart
round: 347 — the validating round
commit: e78bd8e2
paths: [packages/transport/rpc_dart_http2/lib/**]
status: valid
---

# P-42 — which http2 connection state puts an error in the zone

Two halves. The first drives `RpcHttp2CallerTransport.close()` inside
`runZonedGuarded` and reports both the unhandled-error count AND whether the
close path's `terminate()` branch was reached, read off the transport's own
`'Graceful HTTP/2 shutdown did not complete'` warning. The second asks
`package:http2` directly, one connection state per row.

## Measures

Errors that escape to the zone, per connection state — and, on the transport
half, whether the code under test ran at all.

## Control

The reachability read IS the control, and it is what makes the zeros readable:

```
                                        terminate() branch   unhandled
peer sockets destroyed                  not reached          0
peer goes silent without closing        not reached          0
_gracefulCloseTimeout forced to 1 ms    not reached          0
```

Three arms of zero that mean nothing, because the line never ran. Without that
column this bench supports a CLEAN verdict it has not earned.

## What it found

```
live connection             no rejection
terminate() twice           no rejection
socket destroyed first      no rejection
finish() then terminate()   StateError: Cannot add event after closing
finish() and NOTHING else   StateError: Cannot add event after closing
```

The last row is the one that identifies the source. Add it before believing any
conclusion about the row above it: `finish()` throws after its own future has
completed, so anything still in flight when it lands looks like the culprit.
