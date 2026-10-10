---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r815_secret_in_error.dart
round: 815
commit: 58008489
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_stub.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
promoted: packages/transport/rpc_dart_websocket/test/a_failed_connect_is_a_status_test.dart
---

# P-301 — credentials in a failed connect's message

## Measures

`RpcWebSocketCallerTransport.connect` to
`ws://user:pw-secret@127.0.0.1:<port>/rpc?token=q-secret`, `connectTimeout`
500 ms, against a silent socket, a socket that closes on the first byte and an
`HttpServer` answering 401, each with compression off and on. Prints whether
`'$error'` contains either secret. Then the http caller with
`baseUrl: 'http://user:pw-secret@127.0.0.1:<port>'` against the same three.

```
  failure                 at 58008489        after
  timeout                 userinfo+query     none
  timeout, compressed     userinfo+query     none
  closed mid-upgrade      userinfo+query     none
  closed, compressed      userinfo+query     none
  401                     none               none
  401, compressed         userinfo+query     none
  http: silent / closed / 401   none (messages name the method path only)
```

## Control

The 401 row on the default handshake: round 814 wrote that message without
the uri, and it carries no secret, so the bench tells a message with the uri
from one without.
