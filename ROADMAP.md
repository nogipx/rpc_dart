# rpc_dart Roadmap

## Phase 1 — Transport abstraction [DONE]

**Goal:** Decouple HTTP/2 semantics from `IRpcTransport` so new transports are trivial to implement.

**Status:** Complete. 3-layer architecture implemented, all transports migrated, all tests pass.

### Architecture

```
IRpcChannel              — raw byte pipe (~50 LOC to implement)
IRpcMultiplexedChannel   — multiplexed message channel
  +- RpcFrameMultiplexedChannel  — wraps IRpcChannel with frame codec
  +- RpcDirectMultiplexedChannel — zero-copy paired messages (in-memory)
RpcChannelTransport      — wraps IRpcMultiplexedChannel into IRpcTransport
                           (stream IDs, security policy, health)
```

### Done

- [x] `IRpcChannel` interface — raw bidirectional byte pipe
- [x] `IRpcMultiplexedChannel` interface — multiplexed message channel between raw channel and transport
- [x] `RpcChannelFrame` codec — 9-byte multiplexed wire format (4B streamId + 1B flags + 4B length + payload)
- [x] `RpcFrameMultiplexedChannel` — wraps `IRpcChannel` with frame encoding + read buffer
- [x] `RpcDirectMultiplexedChannel` — zero-copy paired channel for in-memory transport
- [x] `RpcChannelTransport` — wraps any `IRpcMultiplexedChannel` into full `IRpcTransport`
- [x] `RpcChannelTransport.pair()` — frame-based pair for testing
- [x] `RpcChannelTransport.memoryPair()` — zero-copy pair (replaces old `RpcInMemoryTransport` internals)
- [x] `RpcInMemoryTransport.pair()` — backward-compatible delegate to `memoryPair()`
- [x] Tests for frame codec, multiplexing, buffer reassembly, error propagation, health
- [x] All 543 core tests pass
- [x] Migrate `rpc_dart_websocket` — `RpcWebSocketChannel implements IRpcChannel`, 750 LOC removed
- [x] Migrate `rpc_dart_isolate` — `IRpcMultiplexedChannel` on both IO and Web, ~1200 LOC removed
- [x] `RpcWebSocketCallerTransport` — reconnect support via stable stream forwarding
- [x] `RpcWebSocketResponderTransport` — thin wrapper around `RpcChannelTransport.fromChannel()`

### Not migrated (by design)

- `rpc_dart_http` — unary HTTP/1.1, no persistent connection, no multiplexing needed
- `rpc_dart_http2` — native HTTP/2 multiplexing, will get gRPC wire format in Phase 2

### Design decisions

- 3-layer split: multiplexing is separate from transport policy (enables swapping frame formats for Phase 2)
- HTTP/2 keeps implementing `IRpcTransport` directly (native multiplexing)
- `IRpcChannel` targets byte-oriented transports (WebSocket, raw TCP, Unix socket, QUIC, etc.)
- `RpcTransportMessage` stays as the high-level unit endpoints see — no breaking changes
- Sync broadcast controllers in DirectMultiplexedChannel and ChannelTransport to minimize async hops

---

## Phase 2 — Full gRPC wire compatibility [NOT STARTED]

**Goal:** Any standard gRPC client (grpcurl, Postman, Go, Python, etc.) can talk to rpc_dart server over HTTP/2. And rpc_dart client can talk to any gRPC server.

**What this means:**

Wire format on HTTP/2 transport must exactly match the gRPC spec:
- HTTP/2 with `Content-Type: application/grpc[+subtype]`
- Length-Prefixed Message framing (1 byte compressed flag + 4 bytes length + payload)
- Request metadata as HTTP/2 headers (`:method POST`, `:path /Service/Method`, etc.)
- Response trailers with `grpc-status`, `grpc-message`, `grpc-status-details-bin`
- Timeout via `grpc-timeout` header
- Compression via `grpc-encoding` / `grpc-accept-encoding`

**What does NOT change:**
- Non-HTTP/2 transports (in-memory, isolate, WebSocket) keep their own wire format.
- Contract/endpoint layer stays the same.
- Annotation-based codegen stays the same.

**Tasks:**
- [ ] Audit current framing against gRPC spec, fix deviations
- [ ] Proper gRPC request/response header sets
- [ ] Trailers-Only responses for errors
- [ ] grpc-status-details-bin (structured error details via protobuf Any or equivalent)
- [ ] Validate with `grpcurl` and a reference Go/Python gRPC client
- [ ] gRPC Health Checking Protocol (grpc.health.v1)
- [ ] gRPC Server Reflection (optional, for tooling)

**Non-HTTP/2 transports:**
These are not "gRPC" and don't need to follow the spec. They use a simpler internal framing format. The contract layer is the same, only the wire format differs.

---

## Phase 3 — Codec negotiation [NOT STARTED]

**Goal:** Client and server negotiate serialization format. Multiple codecs (CBOR, protobuf, JSON) coexist.

**How it works (gRPC standard):**

1. Client sends `Content-Type: application/grpc+cbor`
2. Server checks if it has a codec for `cbor`. If yes, uses it. If not, returns `UNIMPLEMENTED`.
3. Each codec registers with a content subtype string.

**Design:**

```dart
/// Registry of codecs by content subtype.
abstract class IRpcCodecRegistry {
  /// Register a codec factory for a content subtype (e.g. 'cbor', 'proto', 'json').
  void register(String subtype, IRpcCodecFactory factory);

  /// Resolve a typed codec for a given subtype.
  IRpcCodec<T> resolve<T>(String subtype);

  /// List of supported subtypes for content negotiation headers.
  List<String> get supportedSubtypes;
}

/// Creates codecs for specific message types.
abstract class IRpcCodecFactory {
  IRpcCodec<T> create<T>();
}
```

**Built-in codec factories:**
- `CborCodecFactory` — current behavior (T.fromJson + CBOR encoding). Default.
- `JsonCodecFactory` — JSON serialization (T.fromJson + JSON encoding).
- `ProtobufCodecFactory` — protobuf (requires generated .pb.dart). Optional package.

**Migration:** `RpcCodec<T>.withDecoder(T.fromJson)` continues to work as the CBOR factory. No breaking change for existing users.

---

## Phase 4 — Structured concurrency (CallScope) [NOT STARTED]

**Goal:** Automatic resource cleanup for every RPC call. Eliminate manual StreamSubscription tracking.

**Design:**

```dart
abstract class RpcCallScope {
  /// Cancel signal (from client, deadline, or explicit cancel).
  CancellationToken get cancellation;

  /// Register cleanup callback — runs when scope closes (any reason).
  void onDispose(FutureOr<void> Function() callback);

  /// Wrap a stream so it auto-cancels when scope closes.
  Stream<T> track<T>(Stream<T> stream);

  /// Remaining time until deadline (null = no deadline).
  Duration? get remaining;
}
```

Every interceptor, middleware, and handler receives `RpcCallScope`. When the call ends (success, error, cancel, deadline), all tracked resources clean up automatically in reverse order.

Replaces manual `_cancellationSubscription`, `_responseSubscription`, `_messageSubscription` tracking in stream processors.

---

## Phase 5 — Client-side resilience [NOT STARTED]

**Goal:** Production-grade client reliability via composable interceptors.

**Components:**

| Component        | Description                                                     |
|------------------|-----------------------------------------------------------------|
| Circuit breaker  | Fail fast when a service is down. States: closed / half-open / open. |
| Retry            | Per-method retry with backoff. Budget-based (max 10% retries).  |
| Hedging          | Send N parallel requests, take first. Idempotent methods only.  |
| Load balancer    | Round-robin / weighted / least-connections over a connection pool. |
| Deadline propagation | End-to-end enforcement of remaining time budget.            |

All implemented as `IRpcInterceptor` on `RpcCallerEndpoint`. Composable and optional.

---

## Execution order

Phases 1-3 are coupled and form one release (transport + gRPC + codecs).
Phase 4 is independent, can be done in parallel.
Phase 5 builds on top, incremental.

```
Phase 1 (transport) ──> Phase 2 (gRPC) ──> Phase 3 (codecs)
                                                    \
Phase 4 (call scope) ── independent ─────────────────> Phase 5 (resilience)
```