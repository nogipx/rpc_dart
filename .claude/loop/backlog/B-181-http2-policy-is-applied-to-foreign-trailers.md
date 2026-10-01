---
status: closed (round 567)
round: 567
commit: 79ac607e
release: breaking
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: P-189
reason: "bench — CONFIRMED against a control and fixed at BOTH sites of the class: the http2 caller this lead names, and core's `_validateInbound`, which it does not and which websocket, isolate and in-memory inherit"
---

# B-181 — http2 caller: our header policy is enforced on the peer's trailers and destroys the real status

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`http2HeadersToRpcMetadata(..., policy: _policy)` and `_policy.validateMetadata` run on trailers too; a foreign server's `grpc-status-details-bin` over 8 KiB, raw UTF-8 in `grpc-message`, or more than 128 headers throws — the consumer gets INVALID_ARGUMENT then a synthesised UNAVAILABLE instead of the real status, and each counts toward the 256 violations that close the connection.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1243-1249, 1308-1312`.

## Why it matters

Interop with grpc-go/grpc-java servers that attach rich error details.

## Witness a round would build

grpc-go server returning a status with 10 KiB of details.

## Fix sketch

Always extract `grpc-status`/`grpc-message` first; apply limits as caps, not
refusals, on trailers.

## Outcome (round 567) — CONFIRMED, and the class has two sites

`../rounds/567-our-limit-on-their-answer.md`. Bench `P-189`.

```
http2 caller, a server answering grpc-status 9
  CONTROL  details-bin 16 B      status 9 -- the precondition failed
  WITNESS  details-bin 10 KiB    status 3 -> status 9
  WITNESS  200 trailer headers   status 3 -> status 9

core channel transport, client role (NOT named by this lead)
  CONTROL  details 16 B          [frame(no status), status 9]   errors none
  WITNESS  details 10 KiB        [frame(no status)] + RpcFrameException
                              -> [frame(no status), status 9]   errors none
```

**The confidence line was right and the prediction was half right.** The status IS destroyed —
`status 3`, naming our own limit, where the server said 9. What was NOT observed is the
synthesised UNAVAILABLE behind it: the violation reaches the caller first and fails the call, so
the second terminal event never surfaces (`B-189`'s subject, and an instance of why it is hard
to see).

**The second site is core's `RpcChannelTransport._validateInbound`**, which websocket, isolate
and in-memory all inherit, and which dropped the whole trailer frame. Found by sweeping
`validateMetadata` across every `lib/` before touching anything. HTTP/1.1's caller validates
only OUTBOUND; that it does not check inbound response headers at all is `B-145`, the opposite
defect.

**The fix is the lead's own sketch, with one correction.** "Apply limits as caps, not refusals"
is not what landed — a cap would hand the application a value the policy refuses. Instead a
response frame carrying `grpc-status` is REDUCED to that status: the status survives,
`grpc-message` rides along only if it passes the same check, everything else is dropped, and the
violation is still charged to the 256-violation budget. In core it is gated on the CLIENT role,
so a hostile client cannot put `grpc-status` on a request to get a frame delivered.

The limits never protected anything on this path: the frame is decoded and resident before
either check runs.

## Owner decision

—
