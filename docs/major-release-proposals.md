# Major release: proposed decisions

Companion to [audit-2026-10-18-code-quality.md](audit-2026-10-18-code-quality.md).
Each proposal names the audit findings it closes (D = defect, X = cross-cutting,
C = rpc_dart, T = transports, P = companions). API sketches are signatures only.

A major release lets the public API change. The proposals use that where it
removes a whole class of drift, not to rename things for taste.

## Principles

1. **One home per rule.** A status mapping, a size formula, a lifecycle step is
   written once. Every other site calls it. A rule written twice drifts; the
   audit found the drift in every slice.
2. **Forgetting must be a compile error.** Where code has to forward or handle
   something (a transport capability, a call shape), the type system says so.
   Today the cheap mistake is silent: a wrapper that forgets a capability gets
   the default.
3. **The public surface is chosen, not left over.** Today it is everything
   without an underscore, minus a `hide` list. Machinery leaks by default.
4. **Users and transport authors get different libraries.** An application
   needs contracts, endpoints, context, errors. A transport author also needs
   parsers, routers, backpressure helpers. Mixing them makes every internal
   helper a public promise.
5. **Comments describe the code as it is.** History goes to git and the
   journal.

## 1. Library layout and the public surface

Closes X7 partly, C17, enables C1, X2, X3, T6.

| Library | For | Contains |
|---|---|---|
| `package:rpc_dart/rpc_dart.dart` | applications | contracts and annotations, endpoints, `RpcContext`, errors, codecs, `RpcSecurityPolicy`, resilience, logging, `RpcClientConnection` |
| `package:rpc_dart/transport.dart` | transport authors | `IRpcTransport`, `IRpcChannel`, `RpcChannelTransport`, frame and message codecs, `RpcMessageParser`, `RpcStreamRouter`, `BufferedBroadcastController`, `RpcWriteBacklog`, `RpcConnectionHost`, drain helpers, status/trailer factories |
| `package:rpc_dart/transport_io.dart` | io transport authors | `dart:io`-only helpers: the header-bounded server socket (T6) |

- Both barrels use `show` lists. A new public type is added to a list on
  purpose, so the lists are the committed record of the surface.
- `transport.dart` re-exports `rpc_dart.dart`; a transport imports one library.
- `rpc_dart.dart` keeps re-exporting `dart:typed_data`: payloads are
  `Uint8List`, and generated `part` files cannot import it themselves.
- `transport_io.dart` arrives with the header-bounded socket (T6, phase 1).
- Hidden from all barrels: the call-shape classes (`UnaryCaller`,
  `UnaryResponder`, `ServerStreamCaller`, `ClientStreamCaller`,
  `BidirectionalStreamCaller` and their responders), registration types,
  processors, pumps. Outside core they are used only by tests, one example and
  the benchmark. Those move to `src/` imports in this repo.
- `core/drain.dart` moves to `integration/`; `buffered_broadcast.dart` stops
  importing the public barrel (C17).

Migration: an application that imported only `rpc_dart.dart` and used
contracts and endpoints sees no change. Code that built `UnaryCaller` and the
like by hand switches to endpoint calls.

## 2. Transport capabilities: members, not markers

Closes X1, D4, the drift in five forwarders, T7.

**Problem.** Eight optional capabilities are separate interfaces found with
`is`. A decorator that implements `IRpcTransport` and forwards every member
still hides them, and nothing reports it. Five forwarders exist; each forwards
a different subset.

**Decision.** Fold the capabilities into `IRpcTransport` as members with safe
defaults. `IRpcTransport` stays an `abstract class`:

- A transport that `extends` it gets the defaults and overrides what it has.
- A decorator that `implements` it must write every member, so a forgotten
  capability is a compile error. That is the point.

```text
abstract class IRpcTransport {
  // existing members ...

  RpcSecurityPolicy get securityPolicy => const RpcSecurityPolicy();
  Future<void> get ready => Future.value();
  Future<bool> resetStream(int streamId, {String? reason}) async => false;

  // flow control: null when the transport does no flow control
  IRpcFlowCredit? get flowCredit => null;           // defer / return credit
  bool get grantsMessageCredit => true;             // was IRpcNoMessageCredit
  IRpcConnectionBuffer? get connectionBuffer => null; // charge / release

  // required: every transport mints stream ids
  int get lastIssuedStreamId;                       // was IRpcStreamIdSequence
  void resumeStreamIdsAfter(int streamId);
}
```

- `IRpcNoMessageCredit` becomes a bool with the safe polarity kept (`true` keeps
  the depth bound).
- Grouping flow control and the buffer total into small nullable objects keeps
  `IRpcTransport` readable and lets a decorator forward a whole group with one
  line.
- The stream-id members have no default. Every transport mints ids, and
  `RpcClientConnection` needs the watermark to keep ids unique across
  connections; a default would let a transport without one into the proxy.
- `IRpcReconnectableTransport` disappears with in-place reconnect (section 6).

Consequences:

- `RpcWebSocketResponderTransport`, `RpcWebSocketCallerTransport` and
  `RpcSocketCallerTransport` become thin subclasses of `RpcChannelTransport`.
  `RpcChannelTransport` takes `ready:` and reports degraded health until it
  completes. The class names stay, so user code that names them still compiles.
- http2's `_CapabilityPreservingTransport` goes. The server uses the
  `transportWrapper` result as is; a wrapper that `implements IRpcTransport`
  forwards every member, and the compiler checks it.
- `RpcWasmBridge` implements `IRpcChannel` and `_RpcWasmChannel` goes (T7).
- `RpcInMemoryTransport` goes; `RpcChannelTransport.memoryPair()` replaces it.

**Alternative considered:** `T? capability<T>()` with a default body. It is one
method to forward, but a missed forward is still silent, which is the defect
being fixed. Rejected.

Migration: a third-party transport that `implements IRpcTransport` adds the new
members (or switches to `extends`). One `is` check per capability in user code,
if any, becomes a member read.

## 3. Shared transport machinery in core

### 3a. `RpcWriteBacklog`

Closes X2.

One class in `transport.dart`, `dart:async` only:

```text
final class RpcWriteBacklog {
  RpcWriteBacklog({required int? maxUnsentBytes}); // null: never pauses
  static const int defaultServerMax = 1024 * 1024;

  /// Writes source to sink through addStream; counts what the sink took.
  Future<void> pipe(Stream<List<int>> source, StreamConsumer<List<int>> sink);
  /// The reader to pause past the max and resume at half.
  void attachReader(StreamSubscription<Object?> reader);
}
```

- `pipe`, not a wrapped `outgoing` stream: dart:io can end a write without
  cancelling the stream it reads (a raw-socket error completes `addStream`
  and leaves the subscription paused), so only the `addStream` future says the
  write ended.
- Behaviour kept from websocket: the reader resumes when the write ends, so a
  failed write cannot leave a peer paused for ever. http2 gains this.
- socket, websocket and http2 delegate. The three `1024 * 1024` constants become
  `defaultServerMax`.

### 3b. `RpcConnectionHost`

Closes X3, the websocket double logging, the socket factory dropping
`prefaceTimeout`.

The per-connection half of a server: the endpoint set, endpoint creation for a
transport, release when it ends, the connection cap with its warn-once,
drain-then-close.

```text
final class RpcConnectionHost {
  RpcConnectionHost({
    required RpcServerMode mode,
    int? maxConnections,
    LogScope? logger,
    LogController? endpointLogger,
  });
  bool admit({int pending = 0});   // pending: handshakes the server holds
  RpcEndpointBase serve(IRpcTransport transport,
      {required Future<void> done, String? debugLabel, void Function()? onRelease});
  void release(RpcEndpointBase endpoint);  // idempotent
  List<RpcResponderEndpoint> get responders;
  Future<void> stop({Duration? drainTimeout});
}

sealed class RpcServerMode {}
final class RpcResponderMode extends RpcServerMode {
  const RpcResponderMode(void Function(RpcResponderEndpoint) register);
  RpcResponderMode.contracts(List<RpcResponderContract> contracts);
}
final class RpcPeerMode extends RpcServerMode {
  const RpcPeerMode(void Function(RpcPeerEndpoint) register);
}
```

- `RpcServerMode` replaces the `onEndpointCreated` / `onPeerEndpointCreated`
  pair and its "not both" runtime guard.
- The two modes are public classes, not factories, so a responder-only server
  says so in its type: `RpcHttp2Server` and `RpcHttpServer` take
  `RpcResponderMode`, socket and websocket take `RpcServerMode`. A peer mode
  given to http2 is a compile error.
- The policy stays with the server: the host never builds a transport.
- `RpcApp.server`'s builder receives an `RpcResponderMode` instead of a
  callback: `server: (mode) => RpcHttp2Server(port: 50051, mode: mode)`.
- The servers keep only what is theirs: accepting, the handshake, how a refused
  connection is told (a raw socket destroys, websocket sends a close code).
- Release is idempotent (socket's version wins), and `onConnectionClosed`
  fires once for every connection, those `stop()` closes included (http2 used
  to skip them).
- The warn-once at the cap resets when a connection is next admitted.

### 3c. One home for status and trailer rules

Closes X5, D2, C3 partly, T2 partly.

In `transport.dart` (and re-exported where applications need them):

- `RpcTrailers`: `status(code, message)` (today's `RpcMetadata.forTrailer`,
  always encoded and trimmed), `cancelled(reason)` (the `x-client-cancelled`
  frame), `requestEndedMidMessage()`, `responseEndedMidMessage()`,
  `fromHttpStatus(int, {String? body})`, `unexpectedContentType(String)`.
- `RpcCallerTrailer` becomes the only caller-side reader: the single-response
  collector shared by unary and client-stream, the END_STREAM status check, the
  "closed without a status" error (with deadline mapping), ping's status parse.
- **Every** error that goes to a peer passes `wireStatusFor`. http2's
  `_answerRejectedStream` included (D2); the `:method` refusal throws an
  `RpcStatusException(invalidArgument)` so it keeps its status.

## 4. Call shapes: one implementation each, one transfer-mode rule

Closes C1, C2, C3, C4, C5, C6, D5, C15 partly.

Possible once section 1 makes the shape classes internal.

- **Unary runs on the processors**, the way server-stream already does:
  - Responder: `StreamProcessor` holds the request until end-of-stream and
    refuses a second one INTERNAL.
  - Caller: `CallProcessor` with the single-response collector (3c).
  - `UnaryCaller` and `UnaryResponder` (about 1700 lines) and the second
    zero-copy unary path go.
  - Kept: the caller does not await its send before waiting for the response
    (the peer may refuse and stop reading).
- **Zero-copy is codecs == null, everywhere**:
  - One branch per shape in the responder pipeline, not two.
  - Zero-copy unary then refuses a second request like codec unary (D5).
- **The transfer mode is decided once**, by the contract, per method, for every
  shape. `transferMode` on `unaryRequest` goes; unary under `auto` behaves like
  the other three shapes.
- **One base class for the responders**: processor, `id`, `done`, bind, close.
  The bidi handler is driven by `BidirectionalStreamResponder` like the others,
  not by the pipeline. `IRpcResponder` gains `done`, so the pipeline needs no
  casts.
- **Pumps**: `SinkPump` gets a failure policy and replaces the two hand-rolled
  request pumps. One response relay serves server-stream and bidi.
- **Small copies go with it**:
  - The codec/zero-copy argument check: once, in the processor.
  - The decompressor: built by the policy-bound parser.
  - One `policyOf` and one client-metadata builder.

Behaviour changes (all deliberate):

- Zero-copy unary refuses a second request.
- `auto` unary on a zero-copy transport serializes when codecs are given, as
  the other shapes do.
- A caller built without a context sends `x-request-id` on every shape.

## 5. Contracts, context, registration

Closes C7, C8, C9, P12.

- **Registration.** The `add*Method` API is already one entry per shape with
  optional codecs; keep it. Internally:
  - One `RpcMethodRegistration` with nullable codecs, in one map.
  - The `IRpcSerializable` bound and `_OpaqueValue` / `_OpaqueCodec` go.
  - `methods` and `zeroCopyMethods` become one read-only `registrations` view,
    or are hidden.
- **Caller and peer contracts** share one private set of four `call*`
  implementations over the caller-pipeline mixin.
- **`RpcContext`** gets one private `_copy({...})`. Every `with*`, `merge`,
  `forward` and builder method calls it. The auth helpers live in one place
  (keep `RpcContextBuilder`'s, drop `RpcContextUtils`' copies).
- **Call tracking** (`cancelMethod`, `trackedMethods`) moves to the caller
  mixin, so `RpcPeerEndpoint` has it too (C21).
- **One enum for the four shapes**: `@RpcMethod` takes `RpcMethodType`;
  `RpcMethodKind` goes. The generator maps enum values by name.

## 6. Reconnect: one strategy

Closes X4. **Decided by the owner: one layer.**

Today three mechanisms solve stale ids after a reconnect:

- `RpcClientConnection`'s proxy with an id watermark;
- websocket's in-place reconnect with membership sets;
- http2's single-flight reconnect.

**`RpcClientConnection` is the only reconnecting layer.**

- A transport that loses its connection closes. `reconnect()` leaves
  `IRpcTransport`, and with it `IRpcConnectionLossReporting` and websocket's
  `reconnectFactory`.
- The retry interceptor asks the connection, not the transport.
- A call on a transport that closed because its connection was lost fails with
  UNAVAILABLE, like a call cut mid-flight; FAILED_PRECONDITION stays for a
  transport this side closed.
- The proxy owns the stale-id guard in both directions. A late frame for a
  stream it opened on an earlier connection is dropped, and a stream the peer
  opened is cancelled locally when its connection goes.
- The proxy reports `connectionBuffer` as null: a buffer total belongs to one
  connection, and the next one starts empty.
- `RpcEndpointBase.reconnect()` goes; `health()` loses `transportOverride`.
- This removes about half of `websocket_caller_transport.dart` and the http2
  reconnect machinery.
- Cost: a websocket user who relied on `reconnectFactory` wraps the transport in
  `RpcClientConnection`. The core docs and the websocket doc already recommend
  that.

## 7. http2 internals

Closes T1, T2, T5, D6-like teardown drift. No public API.

- **One per-stream record** (`_CallerStream`, `_ResponderStream`) holding the
  stream, subscription, parser, pump, flags and flow-control ledger, with
  `dispose()`. The 13 and 9 parallel maps go. Each teardown path removes one
  entry, so the "different subsets" class disappears.
- **One flow-control ledger class** with an `onOverrun` callback, shared by both
  halves.
- **`connect` and `secureConnect`** share one private `_dial(secure:)`.
- **Dead code goes:** `filterStreamEvents`, the unreachable ASCII check,
  `kGrpcUserAgent`'s fixed version.

## 8. Logging, errors, small types

- **Logging (X6).**
  - Every public constructor takes `LogScope? logger`, resolved once to
    `LogScope.noop`.
  - `RpcConnectionLogger` goes; `RpcClientConnection` takes a `LogScope`.
  - The logger itself:
    - `copyWith` on `LogEvent`/`LogSpan`;
    - `RpcLogLevel.fromName`;
    - redaction covers span events (D1);
    - `traceId` on the `LogRecord` base (P8);
    - the console line escaper is shared with rpc_dart_log (D3).
- **Errors (C15).**
  - Every exception lives in `errors.dart`.
  - `RpcException` becomes `abstract base`; the subclasses are `final`.
  - The `IRpcPeerFault` marker goes; check `is RpcPeerFaultException`.
  - `wireStatusFor` then sees the context exceptions too.
- **Policy defaults (T4).** `RpcHttpResponderTransport` and `RpcHttpServer`
  take a non-null `securityPolicy` defaulting to `const RpcSecurityPolicy()`,
  like every other transport. A null policy no longer turns their checks off.
  This lands with section 2, because `securityPolicy` became an
  `IRpcTransport` member there. The internal helpers that take
  `RpcSecurityPolicy?` (http2 common, websocket io connections, the web
  isolate) get the same default.
- **Primitives (C22).** One failure policy, throw `FormatException`:
  - `RpcBool` and `RpcString` stop returning defaults on bad input;
  - `RpcNum` parses ints first.
- **Dead API (C18).** `convertMap`, `RpcCodec.fromBytes`,
  `RpcMessage.endOfStream`, the ignored `capacity`, `platform_error_*`; the
  `RpcCodec` decoder becomes required.
- **Health (D10).**
  - `GrpcHealthCheckContract` is renamed `RpcHealthContract` (rpc_dart's own
    health, CBOR).
  - A real `grpc.health.v1` (protobuf) lives in `rpc_dart_grpc_reflection`,
    which already writes protobuf.
- **Compression (D9, P5).**
  - `selectResponseEncoding` normalises.
  - One bounded gzip inflater: measure single-add against chunked first, keep
    the one that bounds, export it from core for the companion.

## 9. Companions

- **Generator (D8, P1, P7).**
  - Build descriptors through `rpc_dart_grpc_reflection`'s
    `RpcFileDescriptorBuilder`. This is a generator dependency, never a user
    runtime one.
  - The copied writer goes; the descriptor gains `syntax = "proto3"`.
  - Codec overrides are per METHOD (constants keyed by method). Generated
    output changes, so users regenerate.
- **Framework (D11, P2, P3, P4, P9).**
  - Health aggregates typed `RpcHealthStatus` and `endpoint.health()`; maps only
    in `toJson`.
  - One call-observer base in core (start, finish, error, cancel, for every
    shape) replaces ErrorReporting, CallMetrics and `RpcCallSpy`; OTel builds on
    it.
  - Call types are `RpcMethodType`, not strings.
  - `RpcTestApp` runs through `RpcApp` over an in-memory server.
  - Docs fixed.
- **rpc_dart_log (P10, P11).**
  - Its contract is generated.
  - The fake `sessionId` and the hard-coded MCP version go.
  - `approxJsonBytes` moves to core for log, notify and data.
- **isolate (T9).**
  - One base channel for VM and web, with encode/decode as the only difference.
  - One entrypoint typedef; `policy` non-null with the default on every
    platform.

## Sequencing

Non-breaking items can land before the major and shrink it.

| Phase | Content | Breaking |
|---|---|---|
| 0 | D1, D2, D3, D6, D9, D11 fixes (D7 is not a defect); X6 logging fields; X7 comments; C18 private dead code; http2 internals (7) | no |
| 1 | `RpcWriteBacklog`, `RpcConnectionHost`, `RpcTrailers` added; transports switch to them (3) | no (additions) |
| 2 | Library split and `show` barrels (1) | yes |
| 3 | Capabilities as members (2); wrapper classes removed | yes |
| 4 | Call shapes on the processors, transfer-mode rule (4); registration and context (5) | yes, mostly internal after phase 2 |
| 5 | Reconnect strategy (6); policy defaults, errors, primitives, health, logger API (8) | yes |
| 6 | Companions (9); regenerate generated code | yes for generator output |

Phase 2 goes first among the breaking ones: once the shape classes are internal,
phase 4 stops being an API change.

## Owner's decisions (2026-10-18)

Breaking changes are allowed throughout: this is a major release.

1. Reconnect (section 6): one layer, `RpcClientConnection`.
2. Capabilities (section 2): members on `IRpcTransport` with defaults.
3. Policy (T4): non-null, defaulting to `const RpcSecurityPolicy()` like every
   other transport.
4. Health (D10): rename to `RpcHealthContract` and add a real
   `grpc.health.v1`.
5. Primitives (C22): `RpcBool` and `RpcString` throw `FormatException` on bad
   input.
6. Generator codec overrides (D8): per method.

## Migration summary for users

| Was | Becomes |
|---|---|
| `UnaryCaller`, `*StreamCaller`, `*StreamResponder` built by hand | endpoint calls (`unaryRequest`, ...) or generated callers |
| `is IRpcSecurityPolicyAware` etc. | `transport.securityPolicy` etc. |
| `implements IRpcTransport` in a custom transport | add the capability members, or `extends IRpcTransport` |
| `RpcInMemoryTransport.pair()` | `RpcChannelTransport.memoryPair()` |
| `connectionLost` on a transport | `incomingMessages` ends: the transport closes |
| `headersProvider:` on the websocket caller | `headers:` built inside the `RpcClientConnection` factory, which runs for every connection |
| `endpoint.reconnect()` | `RpcClientConnection.forceReconnect()` |
| `onEndpointCreated:` / `onPeerEndpointCreated:` | `mode: RpcResponderMode(...)` / `RpcPeerMode(...)`; contracts only: `RpcResponderMode.contracts([...])` |
| `RpcApp.server(server: (onEndpoint) => ... onEndpointCreated: onEndpoint)` | `server: (mode) => ... mode: mode` |
| `reconnectFactory:` on the websocket caller | `RpcClientConnection` around the transport |
| `transport.reconnect()` | `RpcClientConnection` reconnects; the transport closes |
| `policy: null` on the http server or responder (checks off) | the default policy; pass an explicit `RpcSecurityPolicy` to change limits |
| `RpcBool` / `RpcString` returning a default on bad input | `FormatException` |
| a per-method codec override applied to every method with the same type | applied to its own method only; regenerate |
| `RpcConnectionLogger` | `LogScope` |
| `GrpcHealthCheckContract` | `RpcHealthContract` |
| `transferMode:` on `unaryRequest` | the contract's transfer mode |
| `RpcMethodKind` in `@RpcMethod` | `RpcMethodType` |
| transport-authoring types from `rpc_dart.dart` | `rpc_dart/transport.dart` |
