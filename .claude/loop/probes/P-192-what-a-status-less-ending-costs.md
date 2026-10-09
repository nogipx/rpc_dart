---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b185_missing_status.dart
round: 571
commit: 3044897d
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-192 — what does a status-less ending cost?

## Why it exists

B-185 asked for "status and retry count". **The count is the finding** — a status is only how the
retry gets chosen, and a round that measured the status alone would have reported a naming
disagreement where the damage is work executed more than once. So the server counts requests, and
the method is called `Charge`.

## The harness

**Site 1, http2.** A raw `http2.ServerTransportConnection` that answers headers + a full message
and then, in the witness, ends on the DATA frame with `endStream: true` and no trailers at all.
`requests` counts accepted streams.

**Site 2, core channel transport.** A frame-channel pair where the peer writes the same shape by
hand: initial response, then a payload frame with `isEndOfStream` and no status. `served` counts
opening frames.

An `RpcRetryInterceptor(maxAttempts: 3)` is attached per arm, or not, which is the variable the
middle arm isolates.

## The numbers (round 571)

Before:

```
http2    WITNESS  no trailers, retry      status 14, ran 3 time(s)
         ARM      no trailers, no retry   status 14, ran 1 time(s)
         CONTROL  trailers, retry         returned "ok", 1 time(s)
channel  WITNESS  no status, retry        status 14, served 3 time(s)
         CONTROL  a status, retry         returned "ok", 1 time(s)
```

After:

```
http2    WITNESS  status 13, ran 1 time        CONTROL unchanged
channel  WITNESS  status 13, served 1 time     CONTROL unchanged
```

## Measures

How many times the peer RAN the call, and what the caller was told. The first is the damage; the
second explains it.

## Control

**Two, answering different objections.** The no-retry ARM reads 1 before the fix, which attributes
the 3 to the interceptor rather than to the rig issuing three calls. The trailers-sent CONTROL
returns `"ok"` at 1 execution before and after, which says the interceptor is attached and
working and that the fix did not disable retries generally.

## What it establishes, and what it does not

Establishes that a peer ending without a status caused a unary call to execute three times at two
independent sites, and that reporting INTERNAL instead reduces it to one while leaving the healthy
path untouched.

Does NOT distinguish a dying channel from a forgetful peer at the CORE site. The http2 half makes
that split on `goawayReceived || !isOpen`; the channel transport has no equivalent signal and no
arm here varies it, so its truncated end is now always non-retryable.

Does NOT measure the streaming shapes. Both witnesses are unary, which is where "the work ran" is
sharpest; a server stream cut off after delivering items is the same branch and is not varied.

## Reading

rpc_dart + rpc_dart_http2 — **counts server EXECUTIONS, not statuses**,
because the damage is work re-run: one unary call named `Charge` went `status
14, ran 3 times -> status 13, ran 1`, with a no-retry ARM at 1 that attributes
the 3 to the interceptor and a trailers-sent CONTROL returning "ok" at 1 that
says the interceptor is attached and healthy. Both sites of the class in one
file, the second built by writing the shape by hand on a frame-channel pair.
Does NOT distinguish a dying channel from a forgetful peer at the CORE site —
the http2 half splits on `goawayReceived || !isOpen` and the channel transport
has no equivalent
