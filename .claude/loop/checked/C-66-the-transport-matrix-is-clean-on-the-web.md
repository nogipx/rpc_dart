---
round: 710
commit: 1789ee02
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
scope: [transport x compiler x call shape, after rounds 709-710]
---

# C-66 — the transport matrix is clean on the web

The matrix the owner asked for after round 708, run at `1789ee02`.

**VM** (`.dart_tool/probe/parity_matrix.dart`, groups 1-7, five transports):
group 7 (volume and pace) found B-257 and B-258, both fixed. After them,
memory, isolate, websocket and http2 deliver every group-7 scenario. http1
fails streams past 1024 messages and responses past `maxBufferedBytes`, which
its README states (unary-only).

**Chrome, dart2js and dart2wasm** (`.dart_tool/probe/web_matrix/`):
websocket client to a VM server (hybrid), http1 client to a VM server with
CORS, isolate host to a dart2js web worker. Unary, unicode status, 2 MiB both
ways, 100 concurrent, deadline, 10k small items, slow reader, 60 KiB items to a
slow reader under a 64 KiB limit, cancel mid-stream then reuse, 5k client
stream, 64 x 256 KiB client stream, 3k bidi. All pass on both compilers.

One observation, not a defect: a worker handler awaiting a 300 us timer per
item runs about 10.7 ms per item through the transport against 5.9 ms for the
bare timer loop in the same worker.

Re-run when the frame channel, the web bridge or flow control changes.

## Control

The same scenarios detect what they are meant to: on the VM, group 7 failed
websocket with RESOURCE_EXHAUSTED before rounds 709 and 710, and with
`_messageWindow` forced off the core and websocket witnesses fail again. The
web probe surfaced its own first error under dart2wasm (a JSON number arriving
as `double`), so a failing row is reported rather than swallowed.
