---
status: decided by owner (round 676)
round: — (not re-measured)
commit: 81530a7b
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: .dart_tool/probe/parity_matrix.dart (scenario 1.error-details)
reason: owner decision — the owner asked for the finding to be recorded, not fixed
---

# B-248 — the HTTP/1.1 caller drops the error details

Measured outside a round, by the transport parity matrix (`probe:` above), at the `commit:` sha.

A handler throws `RpcStatusException(3, 'bad', details: [RpcErrorInfo(...)])`.
The caller sees:

```
memory    RpcStatusException/3 "bad" details=[ErrorInfo]
isolate   RpcStatusException/3 "bad" details=[ErrorInfo]
websocket RpcStatusException/3 "bad" details=[ErrorInfo]
http1     RpcStatusException/3 "bad"
http2     RpcStatusException/3 "bad" details=[ErrorInfo]
```

The mechanism, by reading: the HTTP/1.1 caller splits the response headers into
an initial frame and a trailer frame, and only `grpc-status` and `grpc-message`
go to the trailer (`rpc_http_caller_transport.dart:603`).
`grpc-status-details-bin` stays in the initial frame, so the status built from
the trailer has no details. The server does send the header — the CORS policy
lists it for that reason.

## Why it matters

Unmeasured. `RpcRetryInfo` travels in the details. Since `98c40093` the retry
and circuit-breaker interceptors treat RESOURCE_EXHAUSTED as retryable only when
it carries `RpcRetryInfo` (`retry_interceptor.dart:211`,
`circuit_breaker_interceptor.dart:98`). On HTTP/1.1 that pushback cannot arrive,
so a server at capacity is never retried. Any other rich detail
(`RpcBadRequest`, `RpcErrorInfo`) is lost the same way.

## Witness a round would build

A server returning `RpcStatusException.atCapacity(...)` behind
`RpcRetryInterceptor`, over http1 and http2. Count attempts per call.

## Fix sketch

Route `grpc-status-details-bin` to the trailer frame with the other two.

## Owner decision

2026-10-07, round 676's batch: **fix** -- route `grpc-status-details-bin` to
the trailer frame.
