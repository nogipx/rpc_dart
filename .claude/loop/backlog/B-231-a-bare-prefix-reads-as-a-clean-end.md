---
status: open
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/audit_consumers_header_only_tail.dart`, not yet registered
reason: "bench — a request stream cut right after a 5-byte prefix that promises a body ends cleanly: client-stream and bidi answer OK with the message dropped"
---

# B-231 — a bare prefix reads as a clean end

Found by the independent audit of 2026-10-02 (cross), reproduced before filing.
New evidence against B-216 (round 554), which covered a cut inside the body only.

## The shape

`holdsPartialFrame => _state.available > 0`. When a chunk ends right after a
prefix, the header is already consumed: `expectedMessageLength` is set and
nothing is buffered, so `available == 0`. `_endRequests` reads false and closes
the request stream cleanly.

## Measured

```
headerOnly   clientStream  handler [msg, clean end]   wire [status 0]
headerOnly   bidi          handler [msg, clean end]   wire [status 0]
headerOnly   serverStream  handler []                 wire []    (B-230)
headerOnly   unary         handler []                 wire [status 13]
partialBody  every shape                              wire [status 3]
```

## Fix direction

`holdsPartialFrame` is also true while a header has been read and its body has
not, the state between frames being the only clean one.

## Owner decision

—
