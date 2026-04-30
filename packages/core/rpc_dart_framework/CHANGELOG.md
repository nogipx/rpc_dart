## 0.3.0

- Resilience primitives moved to `rpc_dart` core: `RpcRetryInterceptor`, `RpcCircuitBreakerInterceptor`, `RpcClientConnection`, `RpcRateLimiter`, `BackoffPolicy`.
- `RpcApp`: added `afterModulesStart` hook for post-startup logic.
- `RpcServerModule`: integrated `RpcHttpServer` support.
- `RpcTestApp`: improved test harness with fault injection via `RpcFaultInjector`.
- `RpcCallSpy`: added call observation for testing and debugging.
- Updated to `rpc_dart: ^3.0.0`.

## 0.2.0

- Added `RpcClientConnection` with reconnect state machine.
- Added per-key dynamic rate limiting with `keyExtractor` to `RpcRateLimiter`.
- Added `perKeyFallback` to `RpcRateLimiter`.
- Replaced `RpcRateLimiter` with pluggable rate limit algorithms.
- Removed `RpcClientModule`; added `RpcClientConnection` tests.

## 0.1.0

- Initial release: `RpcApp`, `RpcModule`, `RpcContainer`, `RpcServerModule`, `RpcIsolateModule`, health monitoring, rate limiter, test harness.
