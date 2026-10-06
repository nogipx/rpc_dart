---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b188_failed_response.dart
round: 664
commit: 32974d54
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-229 — what a failed response still downloads

## Why it exists

B-188: the http2 caller fails a call on its headers (non-200, a 200 that is not
gRPC) and nothing stops the body. The same question applies to every other exit
where the caller has already failed the call: headers its policy refuses, a DATA
frame that does not parse.

## The harness

A raw `package:http2` peer. `ok` and `early` (a 103 then a valid answer) are the
healthy controls. `html503`, `ct` (200 text/html), `garbage` (200
application/grpc, body of `<`) and `badmeta` (200 application/grpc plus a 9 KiB
header) answer 64 x 16 KiB. Each failing arm is driven through the endpoint and
directly on the transport, because the endpoint releases the id when the call
ends and that release resets the stream on its own.

## The numbers

```
round 664 before
  endpoint early      "status 2"   (a valid answer behind a 103 fails)
  endpoint html503    ERROR 2   server sent 32 KiB, RST yes
  direct   html503    ERROR 128 broadcast errors after the end 64  sent 1024 KiB, RST no
  direct   ct         ERROR 128 broadcast errors after the end 64  sent 1024 KiB, RST no
  direct   garbage    consumer errors 64   ERROR 128  sent 1024 KiB, RST no
  direct   badmeta    consumer errors 65   ERROR 129  sent 1024 KiB, RST no
round 664 after
  endpoint early      "ok ok"
  direct   html503/ct ERROR 0   sent 16-32 KiB, RST yes
  direct   garbage    consumer errors 1    ERROR 2    sent 32 KiB, RST yes
  direct   badmeta    consumer errors 1    ERROR 1    sent 32 KiB, RST yes
```

## Measures

At the peer: bytes it managed to send and whether `onTerminated` fired. At the
library: ERROR records through its own `LogScope`, and errors on the broadcast
after that stream's end-of-stream.

## Control

`ok` reads clean before and after. The fix switched off reproduces the before
column (the witness's canary).

## What it establishes, and what it does not

Establishes whether a failed response is reset at the moment the caller fails
it. Does NOT measure what a real proxy's error page costs on a slow link; the
1 MiB body is a size, not a measured page.
