<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Security policy and flow control

`RpcSecurityPolicy` bounds what a peer can make this process hold or do:
message sizes, buffered bytes, stream and handler counts, metadata shape, and
the credit-based flow-control windows. It is input validation and resource
limiting. It is NOT authentication or authorization; do that in an
interceptor or middleware.

## Rules

- The policy lives on the TRANSPORT, not on the endpoint. Endpoints read
  `transport.securityPolicy`. There is no `policy:` on `RpcCallerEndpoint`,
  `RpcResponderEndpoint` or `RpcPeerEndpoint`.
- Pass the same policy to both halves of an in-process pair:
  `RpcChannelTransport.memoryPair(policy: ...)`, `RpcChannelTransport.pair(policy: ...)`,
  or the `RpcChannelTransport(...)` / `RpcChannelTransport.fromChannel(...)`
  constructors. Every other transport package takes a policy parameter too; see
  that package's README for where.
- Defaults are meant for a server exposed to untrusted peers. Change a field
  only to tighten or relax that one bound.
- Construct with `const RpcSecurityPolicy(...)`. There are no preset
  constructors. Nullable fields are disabled by passing `null` explicitly.
- To ship a policy across an isolate or worker boundary use `toMap()` /
  `RpcSecurityPolicy.fromMap(map)`. There is no `toJson`/`fromJson`.
- Byte limits on `memoryPair()` and other zero-copy paths: objects are passed
  by reference, so no bytes exist and `maxMessageLengthBytes` cannot fire.
  Use the depth limit `maxBufferedMessagesPerStream` there, or force
  serialization with `RpcDataTransferMode.codec` on the contract.

```dart
const policy = RpcSecurityPolicy(
  maxMessageLengthBytes: 4 * 1024 * 1024,
  maxConcurrentHandlers: 256,
  halfOpenStreamTimeout: Duration(seconds: 30),
  closeOnProtocolError: true,
  flowControlWindowBytes: null, // disable per-stream window
);

(RpcChannelTransport, RpcChannelTransport) limitedPair() =>
    RpcChannelTransport.pair(policy: policy);

// Crossing an isolate boundary:
final restored = RpcSecurityPolicy.fromMap(policy.toMap());
```

## Fields

| Field | Default | Bounds |
| --- | --- | --- |
| `maxMessageLengthBytes` | 16 MiB | One decoded message, in message bytes. The wire frame may be 5 bytes larger (`maxFramedMessageBytes`). Also caps decompressed size. |
| `maxBufferedBytes` | `null` -> `maxMessageLengthBytes + 5` (`effectiveMaxBufferedBytes`) | Un-consumed bytes queued for one stream, and frame reassembly. |
| `maxMessagesPerChunk` | 1024 | Messages decoded out of one incoming chunk. |
| `maxBufferedMessagesPerStream` | 8192 | Un-consumed MESSAGES (payloads and direct objects) queued for one stream. The only queue bound that sees zero-copy payloads. With `flowControlWindowBytes` on it is also granted to the peer as message credit, so small messages travel at most this many per round trip. |
| `maxActiveStreams` | 4096 | Live streams per connection, both directions. Bounds stream state, not running work. |
| `maxConcurrentHandlers` | `null` (no limit) | Handlers running at once per connection. Slot held until the handler (and its middleware/interceptors, and for streams the response stream) finishes. |
| `maxMetadataBytes` | 64 KiB | Total header name + value text of one inbound metadata block. |
| `maxHeaders` | 128 | Header count per metadata block. |
| `maxHeaderNameBytes` | 128 | One header name; also rejects any char `<= 0x20` or `0x7F`. |
| `maxHeaderValueBytes` | 8 KiB | One header value; value must be printable ASCII `0x20..0x7E` on every transport. Binary goes in a `-bin` key. |
| `maxMethodPathLength` | 1024 (`kDefaultMaxMethodPathLength`) | Length of `/Service/Method`. |
| `closeOnProtocolError` | `false` | `true`: a metadata policy violation closes the whole connection. `false`: only the offending stream is failed. |
| `halfOpenStreamTimeout` | 60 s | How long a peer-opened stream may wait for its first request message before it is reclaimed. `null` disables. |
| `flowControlWindowBytes` | 4 MiB | Per-stream flow-control window, in wire bytes. `null` disables. |
| `flowControlConnectionWindowBytes` | 64 MiB | Sum over all streams of one connection. `null` disables. |
| `initialSendWindowBytes` | 64 KiB | What a sender may put in flight before the peer's first grant. `null` = unbounded until the first grant. |
| `initialSendWindowGrace` | 5 s | How long a sender blocked on the initial window waits for a first grant before treating the peer as not doing flow control (then unbounded). `null` = wait forever. |
| `contentTypeValidation` | `RpcContentTypeValidation.lenient` | Responder side. `lenient` accepts a request with no `content-type`; `strict` refuses it. A present non-gRPC value is refused either way. |

`fromMap` rules: a missing key means the default. For `halfOpenStreamTimeoutMs`,
`flowControlWindowBytes`, `flowControlConnectionWindowBytes`,
`initialSendWindowBytes` and `initialSendWindowGraceMs`, an explicit `0` means
disabled (`null`). For `maxBufferedBytes` and `maxConcurrentHandlers`, absent or
`0` means `null`. For the other int fields a non-positive value falls back to
the default.

Helpers on the policy: `validateMetadata(metadata)` (throws
`RpcMetadataViolation`), `isValidHeaderName`, `isValidHeaderValue`,
`parseMethodPath`, `isValidMethodPath`, and the static
`RpcSecurityPolicy.isAcceptableContentType(value, mode)`.

## What happens when a limit trips

Status codes are `RpcStatus` constants; the caller sees an
`RpcStatusException` (or a subclass) with that `statusCode`.

| Limit | Where | Result |
| --- | --- | --- |
| `maxActiveStreams`, own call | caller, before sending | `RpcStatusException.atCapacity`: RESOURCE_EXHAUSTED with `RpcRetryInfo` (retryable). |
| `maxActiveStreams`, peer's stream | responder | That stream answered RESOURCE_EXHAUSTED (retryable). Connection stays. |
| `maxConcurrentHandlers` | responder, at dispatch | RESOURCE_EXHAUSTED with retry info. Connection stays. |
| `maxMessageLengthBytes`, inbound on a server frame channel | server | Connection closed. The caller sees the call end without a status: UNAVAILABLE. |
| `maxMessageLengthBytes`, inbound on a client frame channel | client | That call fails RESOURCE_EXHAUSTED; other calls continue. |
| `maxBufferedBytes` / `maxBufferedMessagesPerStream` | either side | That stream fails RESOURCE_EXHAUSTED. Connection stays. |
| `maxMessagesPerChunk` | parser | RESOURCE_EXHAUSTED. |
| Metadata (`maxHeaders`, name/value, `maxMetadataBytes`, path), OUTBOUND | sender | `RpcMetadataViolation` thrown locally: INVALID_ARGUMENT. It also `implements ArgumentError`. |
| Metadata, INBOUND, `closeOnProtocolError: false` | either side | Responder answers that stream INVALID_ARGUMENT (bare status, no message); a client fails that call INVALID_ARGUMENT. After 256 violations on one connection it is closed anyway. |
| Metadata, INBOUND, `closeOnProtocolError: true` | either side | Connection closed. |
| Peer response trailers violate policy | client | `grpc-status` (and a valid `grpc-message`) are kept; the rest dropped. The server's status wins. |
| Invalid method path | responder | INVALID_ARGUMENT. |
| Missing/invalid `content-type` | responder | INVALID_ARGUMENT. |
| `halfOpenStreamTimeout` | responder | Stream reclaimed with DEADLINE_EXCEEDED. |

The default retry predicate retries RESOURCE_EXHAUSTED only when it carries
`RpcRetryInfo` (capacity limits). A size-limit RESOURCE_EXHAUSTED fails the same
way on every attempt, so it is not retried. See `errors-and-resilience.md`.

## Flow control

Credit-based, per stream and per connection, enforced by `RpcChannelTransport`
(and so by every transport built on it).

- A sender may have at most `flowControlWindowBytes` un-consumed bytes on one
  stream, and `flowControlConnectionWindowBytes` across the connection. Bytes
  are wire bytes: the same window admits a few large or many small messages.
- When credit runs out, the send awaits. Your `await` on a client-stream /
  bidi send, or the response stream of a server-stream handler, is suspended
  until the receiver consumes. That is the backpressure; do not wrap it in a
  timeout that drops data.
- Credit returns as the RECEIVING APPLICATION consumes, not as bytes arrive. A
  consumer that pauses holds the producer; resuming releases it. A stream
  whose consumer never reads stalls its sender, and on the connection window
  can starve other streams (head-of-line coupling, as in HTTP/2).
- Grants travel on bare metadata frames (`x-rpc-window-update`, connection
  level `x-rpc-conn-window-update` on stream 0). A peer that does not
  understand them ignores them; `initialSendWindowGrace` keeps the sender from
  deadlocking against such a peer.
- A grant clamps to the configured window; it never raises it.
- Transports with native flow control (HTTP/2) should run with these set to
  `null` rather than layer two windows. Follow the transport's README.
- A proxy that strips `x-rpc-*` headers breaks flow control: a sender stalls
  after the initial window until the grace expires. Allow-list `x-rpc-*`.

## Core headers (`RpcHeaders`)

| Constant | Value | Notes |
| --- | --- | --- |
| `contentType` / `contentTypeGrpc` | `content-type` / `application/grpc` | Reserved. |
| `te` | `te` | Reserved; set by HTTP/2. |
| `userAgent` | `user-agent` | Reserved; set by HTTP/2. |
| `grpcTimeout` | `grpc-timeout` | Reserved; derived from the context deadline. |
| `grpcEncoding` / `grpcAcceptEncoding` | `grpc-encoding` / `grpc-accept-encoding` | Compression negotiation; passes through. |
| `grpcStatus` / `grpcMessage` / `grpcStatusDetails` | `grpc-status` / `grpc-message` / `grpc-status-details-bin` | Trailers. |
| `xTraceId` / `xRequestId` | `x-trace-id` / `x-request-id` | Correlation, from the context. |
| `xRouteService` | `x-route-service` | Routing through a proxy. |
| `xClientCancelled` / `xCancellationReason` | `x-client-cancelled` / `x-cancellation-reason` | Reserved. Cancellation notice on transports with no stream reset. |
| `xWindowUpdate` / `xConnWindowUpdate` | `x-rpc-window-update` / `x-rpc-conn-window-update` | Reserved. Flow-control grants. |

`RpcHeaders.reserved` is the set user metadata may not set;
`RpcHeaders.isReserved(name)` checks it case-insensitively. Reserved keys in a
context's headers are silently skipped when the call is sent.

## Pitfalls

- Setting a policy on only one side of `memoryPair`/`pair`: both factories take
  one `policy:` and give it to both halves. A hand-built pair with different
  policies tests limits that production will not have.
- Expecting `maxMessageLengthBytes` to fire over `memoryPair()` or any
  zero-copy transport. It cannot; use `pair()` to test size limits.
- Treating `maxActiveStreams` as a concurrency limit. A handler that ignores
  cancellation keeps running after its stream is reclaimed. Bound work with
  `maxConcurrentHandlers`, sized above your expected long-lived streams.
- `maxMetadataBytes` is not implied by `maxHeaders * maxHeaderValueBytes`
  (that product is 1 MiB).
- Non-ASCII or binary metadata values are refused on every transport. Use a
  key ending in `-bin` for binary, or put text in the message body.
- An oversized REQUEST to a server over a frame channel kills the connection,
  so every in-flight call on it fails UNAVAILABLE, not only the large one.
- `halfOpenStreamTimeout` covers only "opened, never dispatched". A dispatched
  handler waiting on a request stream that never ends is not reclaimed; bound
  it with a deadline.
- `RpcMetadataViolation` is both an `RpcStatusException` and an
  `ArgumentError`; a `catch (ArgumentError)` will catch it.
