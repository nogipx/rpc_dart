---
status: awaiting owner
round: 784
commit: e1ae2a36
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/redirect_follow.dart
reason: owner decision — below the loop's severity bar, and the fix is one line
rank: 5
---

# B-276 — the http caller follows a 303 with its metadata

P-279: on a 303 to another origin, `RpcHttpCallerTransport` lets dart:io
follow it as a GET with an empty body, and every metadata header except
`authorization` goes along. That includes `x-api-key`, the header
`RpcContext.withApiKey` sets, which dart:io's list of credentials does not
name. The call then fails with whatever the new origin answers (here
UNIMPLEMENTED from a 404).

Who can trigger it: the server the caller talks to, which already has the
headers, so the exposure needs an honest server with an open redirect, or a
plain-HTTP path where the headers are readable anyway. That is why it sits
below the bar.

The fix, if wanted: `followRedirects = false` on the request in
`_fireRequest`, so a redirect becomes a refusal like 301/307/308 already
are. An RPC never wants a POST turned into a GET.

## Owner decision

—
