---
status: decided by owner (round 676)
round: — (not re-measured)
commit: 81530a7b
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/core/rpc_headers.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/**]
probe: .dart_tool/probe/parity_matrix.dart (group 2)
reason: owner decision — three small items, low severity each
---

# B-253 — request metadata edges differ by transport

Measured outside a round, by the transport parity matrix (`probe:` above), at the `commit:` sha.

Most request metadata behaves the same on all five transports: custom keys on
all four call shapes, upper-case keys, commas, `-bin`, an 8000-byte value,
non-ASCII refused with 3, `grpc-timeout` / `:path` / `content-type` dropped,
trace and request id carried. Three things differ or break the gRPC rules.

**1. Leading and trailing whitespace.** Value `"  v  w  "`:

```
memory / isolate / websocket / http2   "  v  w  "
http1                                  "v  w"
```

http2 puts the padded value on the wire, and RFC 9113 §8.2.1 forbids a field
value that starts or ends with whitespace, so a strict peer may refuse the
request. Not tested against such a peer.

**2. `grpc-status` in a request reaches the handler** on all five transports.
gRPC reserves the `grpc-` prefix. `grpc-timeout` is already dropped, so the
filter exists but does not cover the prefix.

**3. Transport headers reach the handler's context:**

```
memory / isolate / websocket   grpc-accept-encoding, x-request-id, x-route-service, x-trace-id
http2                          + user-agent
http1                          + user-agent, host, content-length, accept-encoding
```

A handler that reads these works on one transport and not on another.

## Owner decision

2026-10-07, round 676's batch: fix **item 1** (refuse a value with leading or
trailing whitespace on send) and **item 2** (drop reserved `grpc-*` request
headers before the handler). Item 3, transport headers in the handler context,
stays as it is.
