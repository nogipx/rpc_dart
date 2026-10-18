# Code-quality audit: core and transports, 2026-10-18

Scope: `lib/` of every package under `packages/core/` and `packages/transport/`
(about 56k lines). Read-only. Six slices audited in parallel; every finding was
checked in the code by its auditor (both copies read, callers counted with grep;
the analyzer was down). Findings marked **verified** were re-checked for this
summary. Paths are relative to `packages/`.

Each duplication finding answers one question: if the copies were one, whose
behaviour would the shared version keep, and which copies would that change?

## Defects found on the way

These are behaviour, not style. Fix them before the refactors below.

| ID | What | Where | Status |
| --- | --- | --- | --- |
| D1 | Span events skip log redaction: `_redact` copies `events: record.events` untouched, so a span's nested events reach outputs unredacted | `core/rpc_dart/lib/src/logger/log_controller.dart:364` | verified |
| D2 | http2 sends raw error text to the peer: `'Request rejected: $error'`, bypassing the default-deny `wireStatusFor` the other path uses | `transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport_inbound.dart:162` | verified |
| D3 | The log collector console prints remote `message`, `data` and `error` unescaped: CR/LF forge records, ESC acts on the operator's terminal. Core's `ConsoleOutput` escapes them | `core/rpc_dart_log/lib/src/log_console.dart:81-114`, `mcp_buffer.dart:483-519` | verified |
| D4 | `RpcWebSocketCallerTransport` does not implement `IRpcConnectionBufferTotal`, so a peer-mode connection over it does not share the connection-wide buffer limit; effect not measured | `transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:27-32` | verified (interface missing) |
| D5 | Zero-copy unary runs the handler on the first request frame and silently drops a second request; codec unary holds until end-of-stream and answers INTERNAL | `core/rpc_dart/lib/src/endpoint/responder_pipeline_responders.dart:102-106` vs `rpc/streams/unary/responder.dart:566-653` | verified (flag present) |
| D6 | `closeForProtocolError`/`closeForOversize` skip the `_buf` release `close()` does, so the reassembly buffer stays held | `core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart:686-722` | auditor only |
| D7 | The websocket server's explicit-policy ceiling has no floor, unlike the caller's: a strict policy drops the connection instead of refusing one call | `transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart:186-204` vs `websocket_caller_transport.dart:388-394` | auditor only |
| D8 | Generator: the file descriptor omits `syntax = "proto3"` (reads as proto2); a per-method codec override is emitted per TYPE, so it leaks into other methods by declaration order | `core/rpc_dart_generator/lib/src/generator.dart:1389-1396, 413-443` | auditor only |
| D9 | `selectResponseEncoding` compares raw values and returns `"Identity"` for `"Identity, gzip"` | `core/rpc_dart/lib/src/core/compression.dart:222-230` | auditor only |
| D10 | `GrpcHealthCheckContract` uses the service name `grpc.health.v1.Health` but speaks CBOR, so grpc_health_probe and k8s gRPC probes cannot decode it; a comment claims a NOT_FOUND nothing sends | `core/rpc_dart/lib/src/integration/grpc_health.dart:51-93, 196-203` | auditor only |
| D11 | Framework health ignores a reconnecting or degraded transport: it reads `collectEndpointMetrics()['isActive']` instead of the typed `endpoint.health()` | `core/rpc_dart_framework/lib/src/rpc_app.dart:347-348` | auditor only |

## Cross-cutting themes (highest value)

**X1. Capabilities found by `is` force hand-written forwarders, and they have
drifted.** Eight marker interfaces (`core/rpc_dart/lib/src/core/transport.dart:172-327`).
Five forwarders, each with a different subset:
`_ReconnectingTransportProxy` (lacks ConnectionBufferTotal, NoMessageCredit),
http2 `_CapabilityPreservingTransport` (`rpc_http2_server.dart:784-914`, lacks
ConnectionBufferTotal, StreamReset), `RpcWebSocketResponderTransport`,
`RpcSocketCallerTransport`, `RpcWebSocketCallerTransport` (D4). A missed one
silently falls back to defaults. Direction: one `T? capability<T>()` on
`IRpcTransport` with a default body (keeps third-party implementers compiling),
decorators forward that one method. Then `RpcWebSocketResponderTransport` and
`RpcSocketCallerTransport` reduce to `RpcChannelTransport.fromChannel` (plus
readiness forwarding). API: additive in core; deprecations in websocket and
socket. Effort M.

**X2. The write backlog exists three times**, written the same week:
`rpc_socket_channel.dart:142-148, 245-263`, `websocket_bounded_upgrade.dart:300-357`
(`_WriteBacklog`), `http2_write_backlog.dart:17-138`. The 1 MiB constant three
times, the same comment word for word. Only websocket resumes the reader when
the write ends. Direction: one helper in core (needs only `dart:async`), http2's
shape, nullable max, websocket's release. Effort M.

**X3. The per-connection server lifecycle is copied between socket and
websocket**: the not-both guard, `createWithContracts`, warn-once cap, endpoint
creation with orphan release, release, drain-then-close
(`rpc_socket_server.dart:78-108, 375-511` vs `rpc_websocket_server.dart:70-107,
254-479`). Drift: websocket` _release` is not idempotent; the websocket factory
logs every error twice; the socket factory drops `prefaceTimeout`. Direction: a
core helper next to `drainUntilIdle` with the transport-specific refusal as a
parameter. Effort M.

**X4. Reconnect is implemented three times**: `RpcClientConnection`'s proxy
(id watermark), websocket in-place (membership sets, about half of
`websocket_caller_transport.dart`), http2 single-flight. Core and the websocket
doc both call `RpcClientConnection` the recommended way. Owner's design
decision. Effort L.

**X5. Status and trailer rules have no single home.**
- Caller side: the single-response collector is written 3 times
  (`unary/caller.dart:222-419`, `client/caller.dart:107-196`,
  `caller_pipeline.dart:897-926`; the last loses deadline mapping); "non-OK on
  END_STREAM is an error" 3 times with three log levels; `CallProcessor` onDone
  re-implements `RpcCallerTrailer.closedWithoutStatus`; ping parses
  `grpc-status` without the 0..16 clamp.
- Transports: trailers hand-built instead of `RpcMetadata.forTrailer` (8 sites,
  3 encodings, http and http2); "ended mid-message" re-typed in http2 although
  core has `requestEndedMidMessage`/`responseEndedMidMessage`; non-200 and
  content-type mapping in both callers; the `x-client-cancelled` frame built 5
  times.
Direction: core factories, then route every site through them. Effort M.

**X6. The logging rule is broken in about 230 call sites.** Nullable
`LogScope?` with `_logger?.` in the http responder and server, http2 caller,
responder and server, websocket server, the framework (`if (_log?.isDebug ??
false)`);` RpcClientConnection` exposes its own string logger typedef. Only
`RpcHttpCallerTransport` and the socket package follow the rule. Mechanical.

**X7. History and measurements in lib comments**, against the owner's rule:
hundreds of "used to", "measured", "round N", "B-N", commit hashes, MiB tables,
in every slice. One reaches users: the exception text at
`core/rpc_dart/lib/src/contracts/contract.dart:117-118` ("used to silently
replace"). Mechanical, but large.

## rpc_dart

- **C1. Unary is a parallel implementation** beside `CallProcessor` /
  `StreamProcessor`: `UnaryCaller` and `UnaryResponder` (~1700 lines) re-do the
  parser, decompressor, metadata, framing, cancel notice and deadline mapping,
  plus a second zero-copy unary path. The pipeline casts `is UnaryResponder` 3
  times. `ServerStreamResponder` already does "one request, held to
  end-of-stream, a second refused" on the processor. Includes D5. Direction:
  serve unary like server-stream. API: exported classes change. Effort L.
- **C2. The transfer mode is decided in 3 places that disagree**: with `auto`
  and codecs on a zero-copy transport, unary sends an object, the other shapes
  serialize (`_RpcCodecMode`, `caller_pipeline.dart:457, 528`,
  `unary/caller.dart:487-488`).
- **C3. Small copies across shapes**: codec/zero-copy argument check 10 times;
  decompressor closure 4; policy lookup 2 (private to two libraries); client
  initial metadata 3 (drift: `x-request-id`); `_checkContextBeforeCall` 3.
- **C4.** Request pumping hand-rolled twice although `SinkPump` exists; the
  response relay loop twice.
- **C5.** Responder wrappers repeat one skeleton (`done` completer, bind,
  `_isActive`); bidi's handler is driven by the pipeline, server-stream's by its
  responder; `IRpcResponder` exposes only `id` and `close`, hence casts.
- **C6.** Every `_ensure*Responder` has a zero-copy and a codec branch; the bidi
  branches drifted on fault logging.
- **C7.** `RpcContext`'s full constructor is written out 11 times
  (`contracts/context.dart`); auth helpers twice under different names;
  credential stripping twice.
- **C8.** Two registration types (`RpcMethodRegistration`,
  `RpcZeroCopyMethodRegistration`) and a binding with two nullable fields; the
  `IRpcSerializable` bound forces `_OpaqueValue`. API breaking. Effort L.
- **C9.** `RpcCallerContract` and `RpcPeerContract` each carry the four
  `call*` methods.
- **C10.** `RpcChannelTransport` hand-rolls `RpcStreamRouter`, whose own doc
  condemns hand-rolled copies.
- **C11.** The bounded evict-oldest id set 4 times (one borrows a constant
  named for another set).
- **C12.** The frame header is parsed 3 ways in the mux (one allocates per
  chunk); `kFrameHeadroom` and `headerSize` are separate literals;
  `maxFramedMessageBytes` is "one home" yet its formula is repeated 5 times.
- **C13.** CBOR integer header 3 times, map writer 2; docs claim "lax key
  coercion" where the code throws.
- **C14.** `error_details.dart`: length-delimited writes 12 times, the decode
  loop 7, with dead branches.
- **C15.** Exception types live in 4 files; `RpcException` is documented as
  abstract but is concrete; `wireStatusFor` cannot see the context exceptions.
- **C16.** `RpcMetadata` has a second, looser path parser behind getters with
  no lib callers.
- **C17. Layering**: `core/drain.dart` imports `endpoint/`;
  `buffered_broadcast.dart` imports the public barrel.
- **C18. Dead code**: `core/platform_error_io.dart` and `_stub.dart`;
  `convertMap`, `RpcCodec.fromBytes`, `RpcMessage.endOfStream`,
  `RpcList.empty(capacity)` (ignored); `_sendGrpcErrorAndCleanup(context:)`
  passed at 8 sites, never read; `updateContext` self-assignment; unused members
  on `_RpcZeroCopyUnaryResponder`; `_isDoubleTyped` always false.
- **C19.** Logger: records rebuilt by hand 4 times, `LogScope`'s constructor 4
  times, level parsing 5.
- **C20.** Resilience: the pushback rule twice; circuit-breaker method pairs
  identical; rate-limiter counters repeat fields.
- **C21.** Call tracking (`cancelMethod`, `trackedMethods`) lives on
  `RpcCallerEndpoint`, not on the mixin that owns the state, so
  `RpcPeerEndpoint` lacks it.
- **C22.** Primitives: one comparison body copied 12 times; `RpcBool` and
  `RpcString` swallow bad input while the number types throw; `RpcNum` parses
  strings through `double` and loses ints above 2^53.

## Transports

- **T1. http2 per-stream state is spread over parallel maps**: 13 in the
  caller, 9 in the responder, 5 teardown sites each clearing a different subset
  (the code's own comments admit it). Direction: one per-stream record with
  `dispose()`. Effort L.
- **T2. http2 caller/responder copies**: the flow-control ledger; `connect` vs
  `secureConnect`; dial re-implements two helpers; parser construction, DATA
  loop, `_emitStreamError`, bounded close; `_maxPolicyViolations = 256` three
  times.
- **T3.** The http responder re-counts the metadata total `validateMetadata`
  counts right after.
- **T4.** The http responder is the only transport taking a nullable policy
  (null turns its own checks off). Breaking to change; owner's call.
- **T5. http2 dead code**: `filterStreamEvents` (tests only), an unreachable
  ASCII check, a `policy` parameter that is never null, `kGrpcUserAgent =
  'rpc-dart/1.0.0'` matching no version.
- **T6.** The header-limiting server socket is copied between websocket and
  http (~200 lines); sharing it needs an io-only core library.
- **T7.** `RpcWasmBridge` is `IRpcChannel` under another name;
  `_RpcWasmChannel` only forwards it.
- **T8.** The websocket message ceiling is computed twice and the copies
  disagree (D7).
- **T9.** Isolate VM and web channels are parallel copies; the entrypoint
  typedef is declared 3 times; `runRpcIsolateManagerWorker`'s `policy` is
  nullable on web only; two comments name `args[4]` for `args[3]`.
- **T10. Small**: a duplicate `@override` (`websocket_caller_transport.dart:675,
  681`); a wrong barrel comment;` _printable `copies core's` _peerText`.

## Core companions

- **P1.** The protobuf writer is copied between the generator and
  grpc_reflection, justified by "`publish_to: none`", which the reflection
  pubspec does not say (it is published, 0.3.0). Includes D8.
- **P2.** Framework health converts typed statuses to string maps and back;
  the module loop is copied into `RpcTestApp`. Includes D11.
- **P3.** "Observe every call shape" interceptors 4 times (framework
  ErrorReporting, CallMetrics, `RpcCallSpy`, OTel base); call-type strings
  differ (`serverStream` vs `server_stream`); the framework copies never record
  a cancelled stream.
- **P4.** `RpcTestApp` re-implements `RpcApp`'s lifecycle without the shutdown
  timeout and swallows teardown errors.
- **P5.** The compression companion re-implements core's bounded gzip inflate;
  the two disagree on whether one whole-buffer `add` is bounded (measure it);
  minimum sizes 18 vs 20.
- **P6.** grpc_reflection has two protobuf readers; one does not bounds-check
  skips.
- **P7.** Generator internals: two identical codec helpers ignoring their own
  parameters; registration emitters differ only by a name; unused fields.
- **P8.** `LogRecord` lacks `traceId` on the sealed base, so consumers
  type-switch.
- **P9.** Framework dartdoc contradicts the code: a nonexistent
  `RpcClientModule`; "Throws StateError" six times where it throws
  `RpcStatusException`; `onStart`/`onStop` order described backwards.
- **P10.** rpc_dart_log's contract is hand-written (the generator is the
  recommended way); `sessionId` is always 1; the MCP server reports 0.1.0, the
  pubspec is 0.3.1.
- **P11.** `approxJsonBytes` 3 times across log, notify and data.
- **P12.** Two core enums for the four call shapes (`RpcMethodKind`,
  `RpcMethodType`); the generator maps them by hand.

## Considered and not findings

- The servers already share `drainUntilIdle`, `inFlightResponderCalls`,
  `notifyWithoutDying`; http and http2 build on core's `RpcStreamIdManager`,
  `RpcStreamRouter`, `BufferedBroadcastController`.
- `CallProcessor` vs `StreamProcessor` is a real split (caller owns id, deadline
  and cancel; responder owns trailer and encoding).
- `UnaryCaller` not awaiting its send before waiting for the response is
  deliberate and must survive any merge.
- `RpcFlowController` vs `RpcStreamBufferLedger`, http2's own windows, the
  three pre-bind buffers: different jobs.
- Socket refusing with `destroy` vs websocket's close code; the websocket
  server not owning its connection stream; Flutter bridge batching.
- rpc_dart_log and OpenTelemetry do not duplicate each other.

## Suggested order

1. D1-D3: small, real, two of them reachable by a peer.
2. X1: removes a whole class of silent drift and two wrapper classes.
3. X2, X3: fresh copies, cheapest to merge before they drift further.
4. X5: one home for status and trailer rules.
5. C1 (with C2, C3): the largest; changes exported types, so a major version.
6. X6, X7, C18: mechanical, any time.
