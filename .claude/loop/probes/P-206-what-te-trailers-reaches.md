---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b149_what_te_trailers_reaches.dart
round: 586
commit: 3535053a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-206 — what `te: trailers` reaches

## Why it exists

B-149 asks for a browser console, which is out of reach here (B-196, B-215). The
question a VM can answer is a better one anyway: WHERE does the header go?

This responder builds request metadata from every header it received, so a header
nothing uses still travels, and the transport's aggregate `maxMetadataBytes` check
counts it.

## The harness

One real unary call, caller and responder both rpc_dart, over `shelf_io` on a real
socket. The reading is taken on the RESPONDER TRANSPORT's `incomingMessages` — the
metadata the transport emits — not on the handler's `RpcContext`, because those are
two different sets and the difference is the finding.

## The numbers (round 586)

Before:

```
headers delivered   10
names               [accept-encoding, content-length, content-type,
                     grpc-accept-encoding, host, te, user-agent,
                     x-request-id, x-route-service, x-trace-id]
carries `te`        YES
```

After:

```
headers delivered   9
carries `te`        no
```

## Measures

Which request-metadata header names one call delivers to the responder transport,
and how many.

## Control

**The other nine names are the control.** They are unchanged, so `10 -> 9` is the
one header removed and not the metadata path having changed shape.

## What it establishes, and what it does not

Establishes that the header travelled on every call and was charged to the
aggregate metadata bound at the responder.

**Establishes, by reading rather than by this probe, where it STOPPED**: core's
`_createContextFromMessage` excludes `te` by name (alongside `content-type`), so no
handler ever saw it. That exclusion has to stay — `rpc_dart_http2` sends the header
because the gRPC HTTP/2 spec requires it — which is why the fix is in the HTTP/1.1
caller and not in the filter.

Does NOT read a browser. The lead's "Refused to set unsafe header" claim is from
the Fetch spec's forbidden-header-name list and is unverified here; the web gate
cannot run this reliably (B-215).

Does NOT read bytes on the wire. `te: trailers` is 11 characters of name plus
value, counted once per request against `maxMetadataBytes`; the probe reads the
header's presence, not a byte total.
