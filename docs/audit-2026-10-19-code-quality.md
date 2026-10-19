# Code-quality audit after the major-release refactor, 2026-10-19

Scope: `lib/` of every package under `packages/core/` and `packages/transport/`,
after every section of `major-release-proposals.md` was marked done. Read-only.
Five slices were audited in parallel: core `core/` + `codec/` + `primitives/` +
`logger/`; core `rpc/` + `contracts/`; core `endpoint/` + `integration/` +
`resilience/`; the core companions; the transports. Callers were counted with
the analyzer. Findings marked **verified** were re-read for this summary; the
rest are the auditor's reading. Nothing was run. Paths are relative to
`packages/`.

The first audit (`audit-2026-10-18-code-quality.md`) is not repeated. Where one
of its items is still open, the ID is given.

## Defects found on the way

Behaviour, not style.

| ID | What | Where | Status |
| --- | --- | --- | --- |
| R1 | The reconnecting proxy drops `releaseStreamId` for streams the peer opened (`_ownIds` holds only this side's ids), so a peer endpoint over `RpcClientConnection` leaves flow-control and buffer entries on the inner transport for every inbound call until it reconnects | `core/rpc_dart/lib/src/resilience/client_connection.dart:400` | verified (code) |
| R2 | Nothing reports `RpcHealthStatus.reconnecting` any more: the proxy answers `unhealthy 'not connected'` while its connect loop runs, so the framework reads an ordinary reconnect as unhealthy, not degraded | `client_connection.dart:513` | verified (no producer) |
| R3 | A websocket upgrade that completes after `dispose()` cancelled the stream is added to a cancelled, unclosed controller: `out.isClosed` is false, the socket is dropped and never closed | `transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart:240` | verified (code) |
| R4 | `RpcHttpServer.afterModulesStart`: `_mode.register` and `endpoint.start()` sit outside the try, so a throwing register leaves `_binding` true and the endpoint open; a retry logs "already binding" and returns while nothing listens | `transport/rpc_dart_http/lib/src/rpc_http_server.dart:277` | verified |
| R5 | Generator: one request or response type with no fields (Ack, Empty) makes `_buildBytes` return null and the whole `grpcDescriptor` disappears without a warning | `core/rpc_dart_generator/lib/src/generator.dart:1292, 1330` | verified |
| R6 | Generator: descriptor fields of enum, nested-message or DateTime type carry a `typeName` the file never defines; a descriptor-pool client should refuse the file | `generator.dart:1456-1461` | auditor only |
| R7 | OpenTelemetry records UNKNOWN for a plain exception on the server, while `wireStatusFor` sends INTERNAL; the README documents UNKNOWN | `core/rpc_dart_opentelemetry/lib/src/metrics/rpc_status_names.dart:57` | verified |
| R8 | `RpcApp.stop` after a hung `start()` runs `onStop` on every module, not only the started ones; the log line says "stopping what it started" | `core/rpc_dart_framework/lib/src/rpc_app.dart:246` | verified |
| R9 | `RpcApp.health()` before `start()` throws `LateInitializationError` | `rpc_app.dart:43, 312` | auditor only |
| R10 | `SinkPump` logs a failed half-close at error even with `logFailures: false`, which two callers pass | `core/rpc_dart/lib/src/core/sink_pump.dart:104` | verified |
| R11 | `BufferedBroadcastController`'s DATA_LOSS message always names `maxPendingEvents`, also when `maxPendingBytes` dropped the events | `core/rpc_dart/lib/src/core/buffered_broadcast.dart:232` | auditor only |
| R12 | `ConsoleFormat.json` writes NaN and Infinity as bare tokens, so the line is not JSON | `core/rpc_dart/lib/src/logger/outputs/console_output.dart:272` | auditor only |
| R13 | `rpc_log_sources` lists the first ten trace ids ever seen, including ids whose records were evicted | `core/rpc_dart_log/lib/src/mcp_buffer.dart:201-215` | auditor only |
| R14 | The MCP server answers the `notifications/initialized` notification with an `id: null` response | `core/rpc_dart_log/lib/src/log_mcp.dart:234` | auditor only |

## Cross-cutting themes

**Y1. History, measurements and loop jargon in `lib/` comments: about 330
sites**, many in public dartdoc that ships to pub.dev. Per slice: core
`core/`-`logger/` 75, `rpc/`-`contracts/` 79, `endpoint/`-`resilience/` 70,
companions 25, transports 79 (socket none). Kinds: "Measured ... 17.5s",
"round 455", "the lead's", "used to", "existing callers see unchanged
behaviour", references to removed code (`_fcConnStreamId`, `ArchiveGzipCodec`,
`InMemoryTransport`, `RpcServerBootstrap`, `_endpoints`, `fromBytes`). The full
site lists are in the auditors' reports; a sweep reads every file anyway.

**Y2. Public dartdoc that contradicts the code.** Worse than history, because
a user acts on it:
- `RpcDataTransferMode.auto` says only unary passes objects; every shape does
  when `transport.supportsZeroCopy` (`core/rpc_dart/lib/src/contracts/models.dart:11, 18-24`;
  the plan, line 300, states the opposite too). `zeroCopy` names a nonexistent
  `InMemoryTransport`.
- `RpcContext.withAdditionalHeaders` promises count and size caps that moved to
  the policy (`contracts/context.dart:87-97, 475`).
- `RpcRateLimiter` tells the user to call `dispose` to cancel a timer it does
  not have (`resilience/rate_limiter.dart:342`).
- `rpc_dart_websocket.dart:12-16` says `grpcStatusFromHttpStatus` is private; it
  is exported from `transport.dart`.
- The framework barrel lists `RpcRateLimiter` as its own; it is core's
  (`rpc_dart_framework.dart:18`).

**Y3. Code paths that only tests reach.** The refactor moved production onto
the endpoint and processors and left the old entry points:
- the hand-driven bidi responder (`responseSink`, `send`, `isAnswered`) and the
  bidi caller's `requestSink`, `payloadResponses`, `CallProcessor.done`: the
  pipeline has its own copies (`rpc/streams/bidirectional/*.dart`);
- `UnaryCaller`'s `timeout` and empty `close()`; `UnaryResponder` is a
  forwarding shell over `ServerStreamResponder._single`
  (`rpc/streams/unary/*.dart`);
- `RpcMetadata.serviceName` / `methodName` (a second path parser),
  `forClientRequestWithPath`, the `:path` fallback (`core/metadata.dart:150-165, 333-375`);
- `RpcEndpointBase.stop()`, `responderIsListening`, `getCancellationToken`,
  `cancelRequest` (zero references), `validateMethodExists`,
  `registeredMethods` + `registeredMethodBindings` (tests only);
- `RpcResponderContract.serviceNameSuffix` (zero references, and it mutates the
  registry key);
- `RpcMessageProducer`, `RpcNull.fromBytes`, `RpcStreamIdManager.reset`,
  `RpcTransportMessage.isSerialized`, processor `scope` / `isZeroCopy`;
- the socket and core `resumeStreamIdsAfter:` constructor parameter;
- wasm: `RpcWasm.activeEndpoint`, `RpcWasmTransport` as a static forwarder.

Each test that drives these drives a path production never runs. Direction:
delete, move the tests onto the endpoint. Effort M overall.

**Y4. Two public builders for one trailer.** `RpcTrailers.status` forwards to
`RpcMetadata.forTrailer`; 11 core sites and three http2 sites call the latter,
http and two http2 sites the former, and the "wire status to capped trailer"
block is written twice (`_answerActiveStreams`, the ping handler). Section 3c
made `RpcTrailers` the one home. Direction: route everything through it, make
`forTrailer` private, add `RpcTrailers.ofWire`. Verified.

**Y5. Four protobuf wire readers.** `core/error_details.dart:534-697` (the
dart2js-safe one; first-audit C14 still open inside it),
`integration/grpc_health.dart:146-216` (added by the health rewrite),
`rpc_dart_grpc_reflection` `reflection_contract.dart:93-161` and
`proto_parser.dart:252-325` (first-audit P6, never planned; the parser does not
bounds-check its skips). Direction: one reader in core, exported from
`transport.dart`, with the reflection contract's bounds checks. Verified.

**Y6. Peer-triggerable records that repeat.** The house rule is warn-once.
Still repeating: the websocket server's "stopped" warning per connection,
http2's per silent socket, the http responder's ERROR per bad body and per
reclaimed stream, the http caller's per bad response, the transfer-mode
mismatch error per frame (`rpc/streams/base_processor.dart:149`), the
reflection registry's missing-file warning per request. Effort S each.

**Y7. Copied formulas and constants.**
- `maxMessageLengthBytes + messagePrefixSize` five more times beside the
  `maxFramedMessageBytes` getter (`core/security_policy.dart`); `9` as
  `kFrameHeadroom` and as `RpcChannelFrame.headerSize`.
- websocket copies core's private reassembly cap twice
  (`websocket_caller_transport.dart:251`, `websocket_io_connections.dart:206`).
- `_maxPolicyViolations = 256` in two http2 files and in `channel_transport.dart`.
- http2 hand-rolls `RpcRecentIds`, which `transport.dart` does not export.
- The codec / zero-copy argument check is still in `unaryRequest` and
  `serverStream` (`endpoint/caller_pipeline.dart:480, 531`), although the
  processor's `_transferParser` makes it, with other text and synchronously.

**Y8. Three peer-text escapers with different rules**: `_peerText` in the
policy, websocket's `_printable` (first-audit T10), `ConsoleOutput.escapeLine`
(passes C1 and bidi controls). Owner's call whether the console adopts the
stricter rule.

## rpc_dart

- **Responder internals:** two pre-bind buffers where each stream fills exactly one
  (`endpoint/responder_streams.dart:28-29, 401-495`); `_handleUnsupportedZeroCopy`
  repeats `_sendGrpcErrorAndCleanup`; dead `markBoundToMessageStream`,
  `RpcResponderStreamStore.clear`, `containsMethod` and two unused parameters.
- **Client-stream caller:** it arms a second deadline timer next to the
  processor's. Its `TimeoutException` branch is unreachable
  (`rpc/streams/client/caller.dart:243-296`).
- **The END_STREAM status check is written four times** across the
  stream callers, and the in-loop copy shadows the transformer's
  (`rpc/streams/server/caller.dart:117-198`, `client/caller.dart:103`,
  `bidirectional/caller.dart:104`).
- **The retry interceptor** still names and justifies in-place reconnect
  (`_reconnectIfConnectionIsGone`, `resilience/retry_interceptor.dart:153-203`).
  The pushback rule is written twice, in retry and in the circuit breaker
  (first-audit C20). The breaker's method pairs are identical.
- **Logging:** `RpcResponderMethodRegistry` holds a mutable `LogScope`
  reassigned per call. `drain.dart`'s exported helpers take `LogScope?`. Only
  `RpcResponderEndpoint` has `setLogController`.
- **Plumbing:** `inFlightResponderCalls` is exported though `RpcConnectionHost` is its
  only lib caller. `RpcNoConnectionException` is thrown at applications but
  exported only from `transport.dart`.
- **Codecs and types:**
  - CBOR writer: integer-head and map writers are duplicated, and the docs
    promise key coercion that the code refuses (first-audit C13).
  - The mux parses the frame header three ways (C12).
  - `RpcChannelTransport` hand-rolls `RpcStreamRouter` (C10).
  - `RpcChannelFrame.decode` is public and skips the metadata bound.
  - `checkUserHeader` throws the peer-fault type for a local mistake.
  - `RpcNum ~/` does not do what its doc says.
  - `LogScope`'s constructor is written out four times.
- **Message-credit legacy path:** it is reachable only from a hand-crafted
  peer, since the binary frame change excludes old peers
  (`rpc/transports/flow_controller.dart:19-26, 732-750`). Keep or remove: the
  owner's call.

## Transports

- **Server-side logger:** websocket and socket build each connection's transport without a logger,
  so `RpcChannelTransport`'s warnings on the server go nowhere. Isolate `spawn`
  and wasm `fromBridge` take none.
- **Parameter names:** the security policy is `securityPolicy:` on the http
  and http2 servers but `policy:` everywhere else. `platformHandlesPing` is a
  `bool?` defaulted by `??`.
- **http2:**
  - it has no `maxConnections` and never calls `RpcConnectionHost.admit`;
  - its `createWithContracts` drops `logController`;
  - a nullable logger is threaded through the dial helpers.
- **Paused-reader wrapper:** `Http2WriteBacklog.reads` and websocket's
  `_BoundedSocket._guarded` build the same one; it belongs on
  `RpcWriteBacklog`.
- **http metadata total:** the http responder sums it before
  `validateMetadata` does the same (first-audit T3).

## Core companions

- **OpenTelemetry:**
  - it calls `updateContext` twice per call instead of overriding core's
    `contextFor`, which has no overrider anywhere;
  - `OtelRpcInterceptorBase` and `OtelRpcCall` are not exported, though the
    migration table tells users to call `callTypeAttribute`;
  - the `span.end()` guard is written three times.
- **compression:**
  - `maxDecompressedSize` is an `int` with a private `-1` sentinel; core uses
    `int?`;
  - the ISIZE trailer is parsed twice;
  - on the VM the unlimited path uses archive and the bounded one dart:io, and
    CRC32 is recomputed after dart:io already checked it.
- **generator:**
  - unused `_options`;
  - `_transferFromAccessor` runs twice per method;
  - two accessor switches beside `_kindFromAccessor`;
  - the contract constructor is emitted four times;
  - the comments claim a zero-copy filter that does not exist.
- **rpc_dart_log:**
  - the client discards the server's `sessionId` and keeps its own random hex;
  - record-to-JSON and the error-level test are duplicated, along with
    `_e` / `_fmtTime`.
- **Test-only public members:**
  - grpc_reflection: `processRequestForTest`, `parseFileDescriptorSet`;
  - framework: `RpcIsolateModule.initIsolate` / `terminateIsolate`;
  - rpc_dart_log: `LogCollectorOutput`'s diagnostic getters.
- **framework:** `RpcTestApp.start(env:)` rebuilds `RpcAppConfig` field by field.
  The typedef `RpcCallObserver` sits beside core's `RpcCallObserverInterceptor`,
  a different concept.

## Considered and not findings

- No transport checks capabilities with `is` or has `reconnect()`.
  `RpcWriteBacklog`, `RpcConnectionHost` and `RpcWriteCoalescer` are used
  wherever they apply.
- Every interpolating `internal` / `debug` call in the five slices is guarded.
  The unguarded hits do not interpolate.
- The four `_ensure*Responder` methods differ in shape. `_keepCancellable` and
  `_handlerContextChosen` are one mechanism split in two, not a copy.
- `RpcResponderStreamState`, `RpcResponderBufferBudget`, `WebSocketFrameGuard`,
  `kRpcHttpPeerGoneKey`: public names outside every barrel, so internal.
- A relay in `ServerStreamResponder` that stops on `!_isActive` still calls
  `finishSending`. An OK trailer on a cut-short stream was not shown to happen.
- Companion pubspecs allow `rpc_dart >=6.0.0` but use APIs from this refactor.
  Versions are the owner's, at release.

## Suggested order

1. R1-R5, R7, R8, R10: real and small. R1 and R3 leak per connection or per
   call.
2. Y2: public docs that mislead, a few lines each.
3. Y3: the largest. It deletes API and moves tests, which suits this major.
4. Y4, Y5, Y7: one home each. Fresh copies, cheapest now.
5. Y1: a sweep, per package, one commit each. Do it after Y3, which deletes
   many of those files.
6. Y6, Y8 and the per-package lists: mechanical, any time.
