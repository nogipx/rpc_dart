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
