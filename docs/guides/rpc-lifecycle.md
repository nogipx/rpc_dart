<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# RPC call lifecycle

Understanding the **end-to-end lifecycle** of a call helps you reason about
instrumentation, performance optimisations, and where to plug in your own
infrastructure pieces. This guide walks through every stage of a unary call and
highlights how streaming requests build on the same pipeline.

## High-level flow

- **Contract lookup** – caller resolves the contract metadata and chooses a
  transport route.
- **Transport handshake** – a stream ID is reserved and request metadata is
  pushed through the transport.
- **Responder dispatch** – the responder endpoint decodes payloads, finds a
  handler, and executes it.
- **Response & trailers** – results flow back with status trailers, health
  metrics, and optional context data.

## Detailed stages

### 1. The caller prepares the invocation

1. `RpcCallerEndpoint` receives a method invocation such as
   `callUnary<Req, Res>()` from a generated or handwritten caller class.
2. The endpoint resolves the **service name** from the contract and adds routing
   headers (for example `x-route-service`) to the outgoing `RpcContext`.
3. A transport stream ID is reserved via `IRpcTransport.createStream()`. Clients
   use odd IDs, responders use even IDs, as enforced by `RpcStreamIdManager`.
4. Request metadata is emitted first. RPC Dart generates the canonical
   `:method`, `:path`, `content-type`, and `te: trailers` headers using
   `RpcMetadata.forClientRequest()`.

### 2. Encoding the payload

RPC Dart supports three data transfer modes controlled by the responder
contract:

- **Zero-copy** transfers (default when no codecs are provided) push the original
  Dart object straight into `RpcTransportMessage.directPayload`. This is limited
  to transports that return `supportsZeroCopy == true`, such as
  `RpcInMemoryTransport`.
- **Codec** transfers serialise payloads using user supplied `IRpcCodec`
  instances. The built-in `RpcCodec` helper uses CBOR for compact binary data.
- **Auto** mode selects zero-copy when no codecs are supplied and falls back to
  codecs otherwise. This allows you to enable serialisation per-method.

When serialisation is required, RPC Dart wraps your payload with a gRPC-style
5-byte prefix (`RpcMessageFrame.encode`) and emits it through
`IRpcTransport.sendMessage()`.

### 3. Responder-side dispatch

1. The responder endpoint listens on `IRpcTransport.incomingMessages` and groups
   frames by stream ID.
2. Initial metadata is parsed to recover the method path and route the call to a
   registered `RpcResponderContract`.
3. The contract resolves the registration created via `addUnaryMethod` (or a
   streaming equivalent) and decides whether zero-copy is allowed for the
   specific request/response pair.
4. Payloads are either handed to the codec for deserialisation or delivered
   directly to the handler. The handler signature always receives the request
   object plus an optional `RpcContext` that carries headers, deadlines, and
   cancellation tokens.

### 4. Producing responses

- For unary handlers RPC Dart awaits the returned future, serialises or forwards
  the response object, and sends it back via the original stream ID.
- For streaming handlers the runtime creates a **stream processor** that merges
  payload messages with end-of-stream markers (`RpcMessage.isEndOfStream`).
  Bidirectional streams use the same infrastructure in both directions.
- When the handler completes, the endpoint appends a trailer metadata frame with
  the final gRPC status (usually `RpcStatus.OK`).

### 5. Completing the call on the caller side

1. The caller endpoint observes the trailer, converts it into an
   `RpcMessage<T>` with `isEndOfStream = true`, and resolves the pending future
   or completes the response stream.
2. If the trailer carries a non-zero status the endpoint throws an
   `RpcError`-like exception populated with the status code and message for easy
   debugging.
3. Stream IDs are released back to the transport via `releaseStreamId` so that
   future calls can reuse them without reopening the connection.

## Lifecycles beyond unary

### Server streaming

Handlers return `Stream<T>` instead of `Future<T>`. The endpoint listens to the
stream and converts each event into `RpcTransportMessage` frames. The caller
receives a Dart stream that mirrors the server output one-to-one.

### Client streaming

The caller passes a `Stream<Req>` to `callClientStream`. The endpoint pipes each
request event through the same transport stream ID. Once the caller's stream
completes the responder handler is awaited for a single response.

### Bidirectional

Both sides exchange independent streams. RPC Dart reuses the same transport
pipeline but keeps two processors running: one for outbound client events and
one for inbound server events. Flow control and cancellation are handled via the
shared `RpcContext`.

## Where to extend the lifecycle

- Insert **middleware** by implementing `IRpcMiddleware` and registering it on
  the endpoint. Middleware can inspect and mutate requests or responses before
  they reach handlers.
- Observe **diagnostics** by calling `RpcCallerEndpoint.health()` or
  `RpcResponderEndpoint.health()`, which aggregate transport status and endpoint
  metrics into `RpcEndpointHealth` snapshots.
- Custom **transports** hook into stages 2 and 5. Implement `IRpcTransport` to
  connect RPC Dart to any messaging fabric without altering caller/responder
  code.

Understanding these steps makes it easier to decide where to add logging,
metrics, retries, or protocol extensions while keeping application logic clean
and portable.
