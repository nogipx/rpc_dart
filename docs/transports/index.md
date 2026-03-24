# Choosing a Transport

Every transport implements `IRpcTransport`. Swapping transports requires changing only the transport construction — service and contract code stays identical.

---

## Comparison

| Transport | Package | Platforms | Streaming | Zero-copy | Use case |
|---|---|---|---|---|---|
| [InMemory](inmemory.md) | `rpc_dart` | all | all patterns | yes | Testing, same-process services |
| [HTTP/2](http2.md) | `rpc_dart_http2` | native | all patterns | no | gRPC-compatible, production server-to-server |
| [HTTP/1.1](http.md) | `rpc_dart_http` | all (web/wasm) | **unary only** | no | Web clients, simple REST-like APIs |
| [WebSocket](websocket.md) | `rpc_dart_websocket` | all (web/wasm) | all patterns | no | Real-time, browser clients |
| [Isolate](isolate.md) | `rpc_dart_isolate` | IO + web workers | all patterns | no | CPU-bound work in parallel isolates |

---

## Decision Guide

**Testing or co-located services in the same process?**
→ Use [InMemory](inmemory.md). Zero overhead, zero-copy, no ports.

**Native server — need all RPC patterns, TLS, gRPC interop?**
→ Use [HTTP/2](http2.md).

**Browser or web/wasm client?**
→ Use [WebSocket](websocket.md) for full streaming, or [HTTP/1.1](http.md) for unary-only with maximum compatibility.

**CPU-intensive work that would block the main isolate?**
→ Use [Isolate](isolate.md) to offload to a background worker.

---

## Changing Transports

The only change required is the transport construction. Everything else stays the same:

```dart
// Testing
final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

// Production — HTTP/2
final callerTransport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
  port: 443,
);

// Production — WebSocket
final callerTransport = RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
);

// In all cases, the caller and endpoint construction is identical:
final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);
final caller = MyServiceCaller(callerEndpoint);
```