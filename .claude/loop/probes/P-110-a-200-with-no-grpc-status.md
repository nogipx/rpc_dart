---
file: packages/transport/rpc_dart_http/.dart_tool/probe/a_200_with_no_grpc_status.dart
round: 460
commit: 9f148158
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-110 — a 200 with no grpc-status

## Why it exists

B-86's HTTP/1.1 half needed an ending that carries no status, and only a
non-conforming peer produces one — so the server is a raw `HttpServer` rather than
`RpcHttpServer`.

## The harness

`HttpServer.bind`, answering every request with 200, `content-type:
application/grpc`, one well-formed gRPC frame as the body, and `grpc-status`
present or absent by arm. The body is built with the library's own
`codec.serialize` (L-10) so a failure cannot be the body being unreadable.

**200 is the load-bearing choice.** The caller synthesises a status from the HTTP
code for non-2xx (`:345`), so any other code would take that path and the trailer
set would never be empty. The arm only exists at 200.

## The numbers (round 460)

```
200, no grpc-status   status=14 "The stream closed before the peer sent a status"
200, grpc-status: 0   RETURNED "answer" -- a clean success
200, grpc-status: 5   status=5
```

## Measures

What the caller's future did: the returned value, or the status code and message.
The value matters as much as the status — a clean success here would mean the
consumer took a response the peer never vouched for.

## Control

The `grpc-status: 0` arm, on the same raw server. It returns cleanly, so the
refusal in the first arm is the missing header and not the harness or the
hand-built body. The `grpc-status: 5` arm is a second discriminator: an explicit
non-OK status comes back as itself, so the UNAVAILABLE above is not a catch-all.

## What it establishes, and what it does not

Establishes: the shape is reachable from any peer answering 200 without the header,
and the consumer is told, with a message naming the cause.

Does not cover the streaming shapes — they reach the same single terminal emit, but
that is read, not driven. And it says nothing about http2, where the same empty
metadata WAS a defect (round 447): there the transport emitted two terminal
messages and the first closed the consumer before the second could carry a status.

## Reading

rpc_dart_http — a raw `HttpServer`, because only a non-conforming peer ends a
response without a status. **200 is the load-bearing choice**: the caller
synthesises a status from the HTTP code for non-2xx, so at any other code the
trailer set is never empty and the arm does not exist. Body built with the
library's own serializer (L-10). Controls: `grpc-status: 0` on the same server
returning cleanly, and `grpc-status: 5` reported as itself — so the
UNAVAILABLE is neither the harness nor a catch-all
