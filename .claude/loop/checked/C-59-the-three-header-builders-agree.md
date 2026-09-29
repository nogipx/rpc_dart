---
round: 517
commit: 739756f5
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
scope: the request metadata three call shapes put on the wire, with a context and without
---

# C-59 — the three request-header builders agree

B-125 says `UnaryCaller.call`, `CallProcessor._sendInitialMetadata` and `ping()` each
assemble the header map and **have drifted**, with a named consequence: *"with a null
context CallProcessor adds `x-request-id` by constructing `RpcContext.empty()` just to
read an id, the unary copy adds none."*

**That consequence is false.** Read off the wire, the header sets are the same.

```
WITH a context:
  unary  (UnaryCaller)           content-type, grpc-accept-encoding, grpc-timeout,
                                 x-request-id, x-route-service, x-trace-id
  server stream (CallProcessor)  content-type, grpc-accept-encoding, grpc-timeout,
                                 x-request-id, x-route-service, x-trace-id
  ping()                         content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id,
                                 x-rpc-ping-timestamp

With NO context (null):
  unary  (UnaryCaller)           content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id
  server stream (CallProcessor)  content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id
  ping()                         content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id,
                                 x-rpc-ping-timestamp
```

**The null-context row is the one the lead is about, and unary carries
`x-request-id` there.** So does `x-trace-id`.

The two differences that do exist are both correct:

- `grpc-timeout` appears only when a context carried a deadline. A call with no
  deadline has no timeout to declare.
- `ping()` adds `x-rpc-ping-timestamp` and never carries `grpc-timeout`. It is a
  different operation with its own bound, and the extra header is what the pong is
  measured against.

## Control

**The with-context rows are the control on the without-context rows.** `grpc-timeout`
appears in the first set and not the second, so the rig is demonstrably capable of
reporting a difference between arms. Three identical blocks with nothing varying would
establish only that the same frame had been read three times.

That is not a formality here. The first version of this rig produced exactly that
failure — see below — and a table where nothing differs is indistinguishable from a
table where nothing was measured.

## How it was checked

`packages/core/rpc_dart/.dart_tool/probe/b125_three_header_builders.dart` — each call
shape driven over a byte pipe, with the header NAMES decoded from the metadata frame
the caller actually sent.

**Read off the wire, not by calling the builders**, for two reasons: two of the three
are private, and what a peer receives is the thing the lead's consequence is about.

**One trap, and it produced a false "they all agree" first.** The transport's own
connection window-update is a metadata frame and it goes FIRST, so "the first metadata
frame" is not the request — every arm initially reported
`x-rpc-conn-window-update` alone. The rig now skips frames carrying nothing but
`x-rpc-` bookkeeping.

## What this does NOT establish

**That the code is not triplicated.** The lead's structural observation stands: three
sites assemble headers, and the risk it names — *"the next header rule lands in one
copy"* — is a real maintainability argument. What is refuted is that the drift has
ALREADY happened, which was the evidence offered for acting now.

Nothing here covers the client-stream or bidirectional shapes, or a context carrying
custom headers, or the responder's side of the exchange.
