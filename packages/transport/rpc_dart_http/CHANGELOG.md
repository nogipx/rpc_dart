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
