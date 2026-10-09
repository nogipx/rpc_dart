---
file: packages/transport/rpc_dart_http/.dart_tool/probe/redirect_follow.dart
round: 784
commit: e1ae2a36
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-279 — redirects the http caller follows

## Measures

Server A answers every request with a redirect status and a `Location` on
server B (another port, so another origin). B records the method, the
`authorization` and `x-secret` headers, and the body size it receives.
`RpcHttpCallerTransport` with defaults makes one unary call whose context
carries `authorization: Bearer secret-token` and `x-secret: tenant-key`.

```
  status   caller sees                          B received
  303      UNIMPLEMENTED (HTTP 404 from B)      GET  auth=null  x-secret=tenant-key  body=0 B
  307      UNKNOWN (HTTP 307)                   nothing
  308      UNKNOWN (HTTP 308)                   nothing
  301      UNKNOWN (HTTP 301)                   nothing
```

## Control

307, 308 and 301: the same server pair and the same call, only the status
differs; B receives nothing. dart:io follows a POST only on 303, turning it
into a GET, and drops `authorization` itself (the Dart 2.16 fix for
CVE-2022-0451); every other header goes to B.
