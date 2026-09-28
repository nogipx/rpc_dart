---
file: packages/core/rpc_dart/.dart_tool/probe/content_type_across_three_layers.dart
round: 462
commit: a4314d4c
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**]
status: valid
---

# P-111 — content-type across the layers

## Why it exists

B-77 says three layers answer "is this content-type gRPC?" three ways. That is a
claim about BEHAVIOUR and the lead derived it from three implementations, so the
bench has to be the matrix itself: every input against every layer, in one run,
with each row reporting what the responder SAW as well as what it answered.

## The harness — three wires, one file

Each layer is reachable only from its own wire, so there are three:

- **HTTP/1.1**: a real `HttpClient` POST against a shelf-hosted
  `RpcHttpResponderTransport`. The shelf handler is wrapped so the row can print
  the content-type the responder received.
- **HTTP/2**: a raw `http2.ClientTransportConnection` against `RpcHttp2Server`.
  The header list is written out by hand, so "absent" is absent by construction —
  nothing between the arm and the socket can add one.
- **core**: a channel pair whose CALLER-side transport is wrapped to rewrite
  `content-type` on every outbound metadata frame. `content-type` is
  `RpcHeaders.reserved`, so an `RpcContext` cannot reach it (round 444 made sure
  of that); below the endpoint is the only place its value can be varied.

A fourth arm was added once the reading found a site the lead's table omits: the
CALLER side, answered by a server returning `200` + `text/html` + an HTML page,
over both HTTP/1.1 and HTTP/2.

**One file in the workspace can import all of this.** A pub workspace centralises
`package_config.json` at the root, so a probe under any member's `.dart_tool/`
resolves `rpc_dart_http`, `rpc_dart_http2`, `shelf` and `http2` together — the
same property that makes the generator's `build_test` goldens impossible here.

## The numbers (round 462)

Responder side, before the fix:

```
                          HTTP/1.1      HTTP/2        core (channel)
(absent)                  415 REFUSED   OK            OK
application/grpc          200           OK            OK
application/grpc+proto    200           OK            OK
text/plain                415 REFUSED   status=3      status=3
```

**Two behaviours, not three.** HTTP/2 refuses `text/plain` although its own file
validates nothing: its metadata goes up to core's pipeline, which is the copy it
inherits.

Caller side, before:

```
HTTP/1.1 caller   status=13 "Invalid compression flag in gRPC message: 60"
HTTP/2 caller     status=13 "Invalid content-type for gRPC: \"text/html\""
```

After the fix, the responder matrix is unchanged, the HTTP/1.1 caller names the
content-type, and the new policy key moves exactly one row:

```
core / HTTP/2, contentTypeValidation: strict
(absent)                  status=3 "Missing content-type for gRPC"
application/grpc          OK
application/grpc+proto    OK
text/plain                status=3 "Invalid content-type for gRPC: \"text/plain\""
```

## Measures

Per row: the HTTP status or grpc-status the LIBRARY produced, a handler-run
counter incremented inside the contract handler, and the content-type the
responder saw. The counter is what separates "refused" from "answered oddly", and
`handler=0` appears alongside `handler=1` in the same run, so a zero is a zero
rather than a dead arm.

## Control

Three, on different axes:

- `application/grpc` in every arm — the spelling the library itself sends — so a
  row that refuses is the input and not the harness.
- `application/grpc+proto`, because that is what the HTTP/1.1 caller actually
  puts on the wire, and a prefix check could pass the bare form and fail this.
- the same input crossed with BOTH policy modes: a mode that changed a present
  value's verdict would make "strict refuses absent" indistinguishable from
  "strict refuses everything".

## What it establishes, and what it does not

Establishes: the responder-side divergence is ONE cell (absent, on HTTP/1.1), not
a three-way split; the policy key reaches core and HTTP/2 and moves only that
cell; and the HTTP/1.1 caller had no response check at all, so a proxy's HTML page
was described as a compression flag.

Does NOT establish the browser half of the HTTP/1.1 responder's strictness. That
site keeps refusing an absent header because a cross-origin POST with a typeless
body sends none and needs no preflight — an argument from the platform and from
the POST-only check's own comment, not something this bench can run.

**A first version of the core arm rebuilt `RpcMetadata` from `headers` alone and
every one of its four rows timed out, control included.** `methodPath` is a
first-class field, not a header, so the responder could not route. A control that
fails the same way as the case is the only reason that was caught in one run
rather than becoming "core accepts everything".
