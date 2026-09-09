---
round: off-journal 77
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/**]
scope: [transports, the http2 server]
---

# C-06 — Sweep of the lifecycle APIs

Measured in **round 77**, off-journal, so `round:` above carries no number —
`lint` reconciles that key against the round files, and there is none.

The clean half of shape U-15. **The lens now exists** —
`../lenses/RPC-21-drive-the-lifecycle-twice.md`, created in the curate pass after
round 234, which is what this record used to ask for; the defects that sweep
found live there. What follows is what came back CLEAN and must not be re-run.

**Stream-id admission leaks in core's caller paths.** `createStream()` reserves
against `maxActiveStreams`, so any path that throws between reserve and release
bricks the transport permanently ("Too many active streams" forever). All four
shapes are guarded: unary has a `finally` release AND runs
`_checkContextBeforeCall()` BEFORE `createStream()`; the streaming
`CallProcessor` calls `createStream()` in its initializer list and wraps the
whole constructor body in `catch { releaseStreamId; rethrow }`; the ping path has
its own `finally`. Each carries a comment naming the leak it prevents.

**The round-76 saturation fix, attacked on its own terms.** RESOURCE_EXHAUSTED is
retryable, so a retry loop reserves an id per refusal — 24/24 refusals stayed
`RpcStatusException(8)` with no slot leak. And that commit's unmeasured claim
that a dead connection with in-flight streams "self-corrects" is now MEASURED: it
converges to UNAVAILABLE/down within 200 ms, because package:http2 terminates
streams on connection death and the `onDone` handler empties `_activeStreams`.

**`rpc_dart_wasm`.** `RpcWasmTransport.close()` delegates to `bridge.close()`,
which unregisters both message handlers, closes both controllers and calls native
`closeRuntime` — no escape-hatch defect of the isolate kind. And
`RpcFlutterWasmBridge.load()`'s `runtimeId != null && error != null` branch,
which would leak a native runtime, is UNREACHABLE: iOS and Android both return
id-xor-error and both close and remove the runtime on the failure path.

**Also clean, same sweep:** `RpcHttp2Server` restart / double-stop / double-start
/ stop-with-live-client; http2 client-stream, bidirectional, throwing handlers,
cancellation and deadline churn (50 expiring calls), counters back at zero.

## Control

A single call to each method: the state returns to where it started, so a defect
would have to come from the second call — and it did, four times, in the records
now held by RPC-21. That is what makes this sweep's clean rows meaningful rather
than a suite that could not see anything.
