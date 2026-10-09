---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b181_foreign_trailers.dart
round: 567
commit: 79ac607e
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-189 — whose answer ends the call when the peer's trailers break our policy?

## Why it exists

B-181 asked for "a grpc-go server returning a status with 10 KiB of details". No grpc-go is
needed: what the defect turns on is a server answering `grpc-status` with one header our policy
refuses, and `package:http2`'s own `ServerTransportConnection` sends arbitrary trailers.

It covers **both sites of the class in one file**, because the sweep found a second one and a
breadth claim that is not measured is a guess.

## The harness

**Site 1, http2.** A raw `http2.ServerTransportConnection.viaSocket` that answers every stream
with `:status 200`, `content-type: application/grpc+proto`, then trailers carrying
`grpc-status: 9`, `grpc-message`, plus whatever the arm attaches. The arm reports what the unary
call threw and the connection's health afterwards. The idiom is
`stream_reset_is_a_status_test.dart`'s.

**Site 2, core channel transport.** Two `RpcChannelTransport`s over a frame-channel pair with
**separate policy objects** — the sender unconstrained, the receiver on the shipped defaults.
Sharing one policy makes a refusal indistinguishable from self-harm (`measurement.md` A3), and
the sender's own outbound `validateMetadata` would otherwise refuse the frame before it ever
reached the victim.

Three arms per site: a small-details CONTROL, and one per limit — `maxHeaderValueBytes` (8 KiB
default) and `maxHeaders` (128).

## The numbers (round 567)

Before:

```
http2 caller
  CONTROL  details-bin 16 B      status 9 -- the precondition failed
  WITNESS  details-bin 10 KiB    status 3 -- Invalid metadata header value
  WITNESS  200 trailer headers   status 3 -- Too many metadata headers

core channel transport, client role
  CONTROL  details 16 B          frames [frame(no status), status 9]   errors none
  WITNESS  details 10 KiB        frames [frame(no status)]             errors RpcFrameException
```

After:

```
http2 caller      all three arms   status 9
core transport    both arms        frames [frame(no status), status 9]   errors none
```

## Measures

What the call ends with — the status a caller would branch on, or the exception type — and the
connection's health level, which separates "this call lost its status" from "the socket died".

## Control

**The small-details arm, at both sites.** It differs from the witness by one thing: the SIZE or
COUNT of a header that is not the status. It read 9 where the witness read 3, so the rig
distinguishes the two and the 3 is not something the harness always produces.

**The connection-health reading is a second control** of a different kind: `healthy` in every
arm, before and after, so none of this is a torn-down socket reporting a lost status.

## What it establishes, and what it does not

Establishes that our inbound metadata limits replaced a server's real status with our own at two
independent sites, that both limits reach it, and that reducing the frame to its status fixes
both without moving the controls.

Does NOT use a real grpc-go or grpc-java peer. The shape under test is a trailer frame our
policy refuses, which `package:http2` produces exactly; what a real grpc-go status proto weighs
in practice is not measured here, only that 10 KiB is past the 8 KiB default.

Does NOT observe the synthesised UNAVAILABLE the lead also predicted. The violation reaches the
caller first and fails the call, so a second terminal event never surfaces — `B-189`.

Does NOT cover the responder role, which is deliberately unchanged, nor HTTP/1.1, which does not
validate inbound response headers at all (`B-145`).

## Reading

rpc_dart + rpc_dart_http2 — what a call ends with when the peer's trailers
break our policy, at BOTH sites of the class in one file: `http2 details-bin
10 KiB status 3 -> 9`, `200 trailer headers status 3 -> 9`, `core channel
[frame] + RpcFrameException -> [frame, status 9]`, against a 16-byte-details
CONTROL reading 9 throughout. **No grpc-go needed** — what the defect turns on
is a server answering a status with one header we refuse, and
`package:http2`'s own `ServerTransportConnection` sends arbitrary trailers.
The core half gives the two sides SEPARATE policy objects, or the sender's own
outbound check refuses the frame before the victim sees it. Connection health
is read in every arm, which separates a lost status from a dead socket
