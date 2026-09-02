<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.4.0

### Fixed

- `RpcCallSpy` bounds what it retains. It kept every observed call forever,
  so leaving it enabled on a long-lived server was an unbounded leak.

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.3.3

**Fixes (audit):**
- `RpcApp._setupEndpoint` no longer swallows a `buildContracts()` failure. Previously a throwing `buildContracts` was logged and ignored, then `endpoint.start()` ran anyway, leaving a live endpoint missing its services (clients got "method not found" instead of a startup failure). The error is now logged with context and rethrown, so `start()` aborts and the normal rollback runs; `endpoint.start()` is not reached.
- `RpcApp.start()` is now single-shot. Previously, after a failed start, calling `start()` again re-entered and reassigned the `late final` lifecycle fields (`_modules`, `_container`, `_env`, `_autoInterceptors`), throwing `LateInitializationError` and masking the original failure. A failed start now surfaces the ORIGINAL exception, and any later `start()` (after success or failure) throws a clear `StateError` ("RpcApp.start() can only be called once; create a new RpcApp to restart."). Note: true restart of an `RpcApp` instance was never supported (the lifecycle fields are `late final`); create a new instance to restart.

## 0.3.2

- Fixed `RpcAppConfig.logController` not being wired to endpoints -- `context.log` now works in responder handlers when `logController` is set in config.

**Fixes (audit):**
- `RpcApp.start()` now rolls back on a partial startup failure: already-started modules get `onStop()`, the transport server is stopped, and spawned isolates are terminated (in reverse order) before the error is rethrown. Previously these resources leaked and the app could not be restarted.
- `health()` now factors endpoint health into the overall `RpcAppHealthLevel` -- an inactive/closed endpoint degrades the app to unhealthy instead of reporting `healthy`.
- `RpcContainer.tryGet<T>()` no longer swallows a `StateError` thrown inside a registered factory (it now checks `has<T>()` first), so factory failures propagate instead of being misreported as "not registered".

**New API:**
- `RpcContainer.registerLazySingleton<T>()` -- memoizes a single shared instance on first `get()` (`registerFactory` keeps its per-call semantics).

## 0.3.1

- Updated to `rpc_dart: ^3.1.0`.

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
