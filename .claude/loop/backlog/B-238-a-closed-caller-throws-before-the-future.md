---
status: open
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/correct_shapes_d.dart`, not yet registered
reason: "cost — after close(), unaryRequest, serverStream and bidirectionalStream throw synchronously; clientStream returns a failed Future"
---

# B-238 — a closed caller throws before the Future

Found by the independent audit of 2026-10-02 (semantics), reproduced before
filing.

## Measured

```
after caller.close():  unary SYNC THROW   serverStream SYNC THROW
                       clientStream failed Future   bidi SYNC THROW
```

`caller.unaryRequest(...).catchError(...)` never sees the error. `clientStream`
moved its guard inside its async closure on purpose; the other three did not
follow.

## Owner decision

—
