---
file: packages/core/rpc_dart/.dart_tool/probe/r830_log_injection_raw.dart
round: 830
commit: 8da0fa28
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
promoted: packages/core/rpc_dart/test/core/a_violation_message_escapes_peer_text_test.dart
---

# P-307 — peer text in log lines

## Measures

A hostile peer that skips the caller's checks: a raw
`RpcFrameMultiplexedChannel` (the library's own frame encoder) sends request
metadata to an `RpcResponderEndpoint` over `RpcChannelTransport`, with a
method path carrying CR/LF or ESC, and a cancel reason with a newline. Prints
the server's log records (every level) that contain CR, LF or ESC.

```
  path / input                  records   with CR/LF/ESC
  /Svc/m (control)              2         0
  /Svc\r\nFORGED/m              2         1  (before the fix)
     "warning: Transport reported a discarded frame (logged once per
      connection): ... Invalid methodPath in metadata: /Svc<CR><LF>FORGED/m"
  /Svc/m\nFORGED LINE           1         0  (the once-per-connection warning
                                              already fired)
  cancel reason "bye\nFORGED"   2         0  (refused as an invalid value,
                                              which is not quoted)
  after the fix: 0 in every row
```

The HTTP/1.1 half (`packages/transport/rpc_dart_http/.dart_tool/probe/r830_log_injection.dart`,
`/Svc%0D%0AFORGED/m` and others) is answered 400 before anything is logged
with the text: 0 in every row.

The first channel version used an ordinary caller, which refuses such a name
locally (`ArgumentError`), so it never reached the server (L-15).

## Control

A plain path: two records, none with a control character.
