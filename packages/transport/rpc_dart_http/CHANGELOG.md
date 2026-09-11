<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.4.0

### Breaking

- **Requires rpc_dart 6.** See its changelog — notably that a handler's bare
  `Exception` text no longer reaches the caller.
- **gRPC is POST-only.** The server executed a handler for any HTTP method.

### Security

- **`maxMetadataBytes` is enforced on inbound headers.** The responder checked
  `maxHeaders` and the per-header caps, which do not imply a total: the defaults
  allow 128 × 8 KiB = 1 MiB against a 64 KiB bound. Measured with raw HTTP/1.1
  POSTs, **960 000 bytes of headers were answered `200 OK`** — 14.6x the bound,
  every header individually legal, before any authentication, and `dart:io`
  imposes no limit of its own.
- **The caller bounds the response body it is willing to buffer.** A server
  bounds what clients send it and forgets it is also a client of its peers: a
  192 MiB body cost 756 MiB of RSS, resident three times over, before the
  parser's own error fired.
- **The refusal path has the deadline it documented**, so refusing is not the
  cheap way to pin a server.
- **The CORS policy applies to rejections too**, with `Vary` marked, and the
  credentials guard holds outside `dart test`.
- **The pipeline stream opens only once the request is in hand.**

### Fixed

- **A connection failure is a gRPC status, not a raw `ClientException`**, and
  closing under an in-flight call gives a status rather than a dropped socket.
- **A big error page no longer destroys the status it carried**, and an
  oversized request is `RESOURCE_EXHAUSTED` rather than `INVALID_ARGUMENT`.
- **The rejection reason reaches the caller** instead of a bare code.
- **A gRPC content type is accepted in any case.**
- **The server starts its own endpoint**, and `stop()` releases a partially
  started one.
- **The stream-id watermark is joined**, so a dead call can no longer fire a
  live request.
- **The security policy reaches the responder pipeline.**
- **Opt-in graceful drain on `stop()`.**

### Performance

- Request and response bodies are buffered as bytes rather than word-sized ints.

### Documentation

- The example no longer teaches accepting any TLS certificate.
- What streaming methods actually do on HTTP/1.1 is stated, along with the
  `", "` header-splitting limitation and the fact that `bodyReadTimeout` rejects
  an `Expect: 100-continue` client.

## 0.3.0

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.2.4

- Deliver the `400` when a request body exceeds
  `RpcSecurityPolicy.maxMessageLengthBytes`. The responder used to stop reading
  the moment the limit was passed, which left unread bytes on the socket;
  dart:io then tore the connection down before the response was flushed and the
  client saw "Connection closed before full header was received" instead of the
  status. The body is now drained to its end (buffer dropped, later chunks
  discarded, so memory stays bounded) before the `400` is returned.
- Validate outgoing metadata on send. Both the caller (`sendMetadata`) and the
  responder (`sendMetadata`) now run `RpcSecurityPolicy.validateMetadata` before
  writing headers, closing the gap where HTTP/1.1 sent metadata without the
  checks every other transport applies. Combined with the core change, this
  enforces printable-ASCII header values (`%x20-%x7E`) — non-ASCII / CR-LF
  values are rejected with an `ArgumentError` instead of corrupting or injecting
  HTTP headers. The caller uses a default `RpcSecurityPolicy`; the responder
  uses its configured `securityPolicy` (or the default when unset).

## 0.2.3

- BEHAVIORAL CHANGE (secure-by-default CORS): `RpcHttpCorsPolicy.allowedOrigins`
  now defaults to `const []` (CLOSED) instead of `const ['*']`. With the closed
  default, cross-origin browser preflights are rejected (`403`, no
  `access-control-allow-origin`) and cross-origin actual requests receive no
  CORS headers, so the browser blocks the response read. Same-origin requests
  (which carry no `Origin` header) are unaffected. The previous allow-any-origin
  default let any web page (including DNS-rebinding / drive-by attackers) call a
  local/internal RPC server. To restore the old behavior, pass
  `allowedOrigins: ['*']` explicitly, or list specific origins.
- Allowing any origin via `allowedOrigins: ['*']` now emits a one-time warning
  (via an optional `logger` on the policy constructor, falling back to stderr),
  noting it is intended for dev / public-API use only. The existing assert that
  `'*'` is incompatible with `allowCredentials` is unchanged.

## 0.2.2

- Server-side hardening. `RpcHttpServer` now forwards a `securityPolicy` and an
  optional `bodyReadTimeout` to its `RpcHttpResponderTransport`. Previously the
  server constructed the transport with only the CORS policy, so request bodies
  reached via the public server API were buffered UNBOUNDED (DoS via large/slow
  POST) and had no read timeout (slowloris).
- BEHAVIORAL CHANGE: `securityPolicy` defaults to a non-null
  `const RpcSecurityPolicy()`, so the built-in `maxMessageLengthBytes` (16 MiB),
  header, and concurrency limits are now ENFORCED out of the box. Requests
  exceeding the body limit are rejected with `400` instead of being buffered.
  Pass `securityPolicy: null` to opt out (not recommended), or a tuned
  `RpcSecurityPolicy` to adjust the limits.
- Added `RpcHttpServer.actualPort` getter (returns the OS-assigned port after
  binding when constructed with port `0`).

## 0.2.1

- Added `test/web_smoke_test.dart`: cross-platform (dart2js) smoke test proving
  the `RpcHttpCallerTransport` client compiles to JS and round-trips a unary
  call without a real server. It injects a `package:http` `MockClient` that
  decodes the gRPC-framed request and returns a canned framed response.
- Wired the http web smoke into the `just test_web` recipe and the `web` CI job
  (runs on `-p node`; also verified on `-p chrome`).

## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- `RpcHttpServer`: added `afterModulesStart` hook support.

## 0.1.0

- Initial release: HTTP/1.1 unary-only transport for rpc_dart using `shelf`.
