<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Integration stream primitives

`package:rpc_dart/internal.dart` is a deliberately selected infrastructure API
for libraries that integrate with rpc_dart. It is not a wildcard export of
`src/`. Its contracts are documented here; callers must not depend on other
implementation files. Application contracts normally use `rpc_dart.dart`.

| Primitive | Ownership |
| --- | --- |
| `StreamSource<T>` | One source subscription, no controller or queue. Defers a factory until `start`, forwards demand, cancels without waiting for arbitrary cleanup, and releases callback captures on termination. |
| `StreamBridge<T>` | A neutral relay built on `StreamSource`. Preserves non-terminal source errors and the existing eager/cold subscription modes. It has no buffer budget. |
| `BoundedStreamBridge<T>` | A lazy, terminal-on-error relay using the same source owner, with one bounded queue. Single-subscription sources receive demand; broadcast sources keep running into the bounded queue. |
| `RpcBufferBudget` | Count and byte accounting for one queue, without payloads or stream identifiers. Failed admission changes neither counter. |
| `RpcStreamBufferLedger` / `RpcBufferAdmission` | Per-stream budgets and a connection total. The transport uses the same `RpcBufferBudget` arithmetic as bounded application queues. The owner must release consumed charges and forget ended streams. |
| `RpcPeerFaultException` | A codec's explicit refusal of malformed peer input, preserving its status instead of reporting a local implementation failure. |

`StreamBufferLimits` is required when constructing the bounded relay, so each
integration chooses its policy explicitly; `StreamBridgeStats` contains
scalar counters and no payloads. Weights are supplied by the integration in one
consistent unit. They need not be exact heap sizes. These helpers never encode
objects and never return transport flow-control credit.

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/internal.dart';

Stream<String> boundedMessages(Stream<String> source) {
  return BoundedStreamBridge<String>(
    source: () => source,
    limits: const StreamBufferLimits(
      items: 16,
      bytes: 64 * 1024,
      elementBytes: 16 * 1024,
    ),
    weigh: (message) => message.length,
    overflowError: () => RpcStatusException(
      RpcStatus.resourceExhausted,
      'message backlog exceeded its limit',
    ),
  ).stream;
}
```

Consumer cancellation releases the owned subscription and queued elements
immediately. It does not wait for a producer's arbitrary cancellation Future.
Owner `fail` terminates the bounded relay with an error; the first error drops
queued data. `close` terminates normally. Normal source completion drains queued
elements first, and an empty paused relay releases its resources before the
consumer resumes to receive `done`.

The RPC call itself still uses the public `RpcCallScope`, `RpcContext` and
`RpcCancellationToken`. Its transport still owns byte windows, credit and wire
buffer limits. Do not add a second `SinkPump` over a native RPC upload; RPC
already sequences its sends and stops pulling when that call ends.
