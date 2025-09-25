# RPC Dart

[![Pub Version](https://img.shields.io/pub/v/rpc_dart.svg?style=for-the-badge&logo=dart&logoColor=white&color=3c69aa)](https://pub.dev/packages/rpc_dart)
[![GitHub Stars](https://img.shields.io/github/stars/nogipx/rpc_dart?style=for-the-badge&logo=github&logoColor=white&color=24292e)](https://github.com/nogipx/rpc_dart)
[![Pub Likes](https://img.shields.io/pub/likes/rpc_dart?style=for-the-badge&logo=dart&logoColor=white&color=86c3f4)](https://pub.dev/packages/rpc_dart)

RPC Dart is a transport-independent RPC framework written entirely in Dart. It
lets you write RPC services once and run them anywhere—mobile, web, desktop, or
server—without coupling your business logic to a particular transport or
serialization strategy.

## Quick start

Install the package:

```sh
dart pub add rpc_dart
```

For Flutter projects run:

```sh
flutter pub add rpc_dart
```

Need optional HTTP, WebSocket, or isolate transports?

```sh
dart pub add rpc_dart_transports
```

Head over to the [Getting started](getting-started.md) guide for a complete
walkthrough.

## Why RPC Dart?

- **Transport independence** – swap between InMemory, HTTP/2, WebSocket, or
  isolate transports without touching your application code.
- **Pure Dart** – works on every Dart platform with zero native dependencies.
- **All RPC patterns** – unary, client streaming, server streaming, and
  bidirectional streaming are all first-class citizens.
- **Zero-copy** – InMemory transport passes objects by reference for
  blazing-fast testing and single-process workloads.

## Key resources

- [Getting started](getting-started.md)
- [Core concepts](core-concepts.md)
- [Architecture](architecture.md)
- [Project repository](https://github.com/nogipx/rpc_dart)
- [Package on pub.dev](https://pub.dev/packages/rpc_dart)

## Need help?

- Browse the [examples on GitHub](https://github.com/nogipx/rpc_dart/tree/main/example)
- Open an [issue on GitHub](https://github.com/nogipx/rpc_dart/issues)
