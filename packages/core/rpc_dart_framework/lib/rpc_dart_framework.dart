// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Server framework for rpc_dart.
///
/// Core building blocks:
/// - [RpcContainer]     — type-keyed DI (singleton + factory).
/// - [RpcEnvConfig]     — typed, parsed access to environment variables.
/// - [RpcModule]        — lifecycle unit: configure DI, build contracts, start/stop/health.
/// - [RpcIsolateModule] — module variant that runs handlers in a dedicated isolate.
/// - [RpcApp]           — application container with signal handling, graceful drain,
///                        topological module ordering, health aggregation,
///                        and auto-wired error/metrics interceptors.
/// - [RpcTestApp]       — in-memory test harness (no network required).
/// - [RpcRateLimiter]   — sliding-window rate-limiting interceptor.
/// - [RpcAppHealth]     — aggregated health report from [RpcApp.health].
/// - [RpcCallEvent]     — per-call metrics record emitted by [RpcAppConfig.onCall].
/// - [RpcAppConfig]     — framework configuration (timeouts, hooks, env override).
library rpc_dart_server;

export 'src/rpc_app.dart';
export 'src/rpc_app_config.dart';
export 'src/rpc_app_health.dart';
export 'src/rpc_call_spy.dart';
export 'src/rpc_container.dart';
export 'src/rpc_env_config.dart';
export 'src/rpc_fault_injector.dart';
export 'src/rpc_isolate_module.dart';
export 'src/rpc_module.dart';
export 'src/rpc_rate_limiter.dart';
export 'src/rpc_test_app.dart';
