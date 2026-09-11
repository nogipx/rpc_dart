---
file: packages/transport/rpc_dart_http/.dart_tool/probe/aggregate_metadata_bound.dart
round: 341 — the validating round
commit: 8a28f1bf
paths: [packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-39 — is the aggregate metadata bound enforced

Sends one raw HTTP/1.1 POST carrying N padding headers of M bytes and reports
the status line. Raw rather than through the caller transport: the question is
what an untrusted PEER can put on the wire, and our own caller would not build
this block.

Vary `(count, size)` in the loop. Both must stay inside `maxHeaders` and
`maxHeaderValueBytes` individually, or the per-header rules refuse it first and
the aggregate is never reached.

## Measures

The HTTP status the server answers, against the total header bytes sent — so a
row is "N bytes of metadata, accepted or refused".

## Control

A second server with `maxHeaders: 8` and the same requests. Without it the 200s
below say nothing: a bench that cannot produce a refusal cannot tell an
unenforced bound from an enforced one.

```
policy maxMetadataBytes = 65536 (maxHeaders=128, maxHeaderValueBytes=8192)

                    header bytes   before        after
4 x 100                      400   200 OK        200 OK
100 x 1000                100000   200 OK        400 Bad Request
120 x 8000                960000   200 OK        400 Bad Request

CONTROL, maxHeaders=8
4 x 100                            200 OK
120 x 8000                         400 Bad Request     <- the bench can refuse
```

**960 000 bytes accepted against a 64 KiB bound**, every individual header legal.
dart:io imposes no limit of its own here, so nothing else was catching it.
