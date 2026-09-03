// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import '../client/i_notify_publisher.dart';
import '../client/i_notify_subscriber.dart';
import '../client/notify_publisher.dart';
import '../client/notify_subscriber.dart';
import '../repository/i_notify_repository.dart';
import '../repository/in_memory_notify_repository.dart';
import '../server/notify_service_server.dart';

/// Factory for creating [NotifyServiceServer] / client pairs.
class NotifyServiceFactory {
  const NotifyServiceFactory._();

  /// Create a server backed by [transport] and [repository].
  ///
  /// The server registers both [NotifySubscribeResponder] (subscribe) and
  /// [NotifyPublishResponder] (publish) on the same endpoint.
  ///
  /// If [repository] is omitted an [InMemoryNotifyRepository] is used.
  ///
  /// A repository passed in belongs to the caller and outlives this server:
  /// [NotifyServiceServer.close] releases the subscriptions and leaves it
  /// running. Only the one created here is disposed with the server — the
  /// distinction matters because a server registers its contracts per
  /// connection, so anything else would end the bus at the first disconnect.
  static NotifyServiceServer createServer({
    required IRpcTransport transport,
    INotifyRepository? repository,
    String debugLabel = 'NotifyServiceServer',
  }) {
    final repo = repository ?? InMemoryNotifyRepository();
    return NotifyServiceServer(
      endpoint: RpcResponderEndpoint(
        transport: transport,
        debugLabel: debugLabel,
      ),
      subscribeResponder: NotifySubscribeResponder(
        subscriber: INotifySubscriber.repository(
          repo,
          ownsRepository: repository == null,
        ),
        dataTransferMode: transport is RpcInMemoryTransport
            ? RpcDataTransferMode.zeroCopy
            : RpcDataTransferMode.auto,
      ),
      publishResponder: NotifyPublishResponder(
        publisher: INotifyPublisher.repository(repo),
        dataTransferMode: transport is RpcInMemoryTransport
            ? RpcDataTransferMode.zeroCopy
            : RpcDataTransferMode.auto,
      ),
    );
  }

  /// Create a [NotifySubscriber] backed by [transport].
  static NotifySubscriber createSubscriber({
    required IRpcTransport transport,
    String debugLabel = 'NotifySubscriber',
  }) {
    final endpoint = RpcCallerEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    return NotifySubscriber.endpoint(endpoint);
  }

  /// Create a [NotifyPublisher] backed by [transport].
  ///
  /// Use this in back-end services that need to push events without direct
  /// access to [INotifyRepository].
  static NotifyPublisher createPublisher({
    required IRpcTransport transport,
    String debugLabel = 'NotifyPublisher',
  }) {
    final endpoint = RpcCallerEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    return NotifyPublisher.endpoint(endpoint);
  }

  /// Full in-memory environment: one transport pair + server + both clients.
  ///
  /// [subscriber] and [publisher] share the same caller-side transport —
  /// RPC multiplexes all calls via stream IDs so a single pair is sufficient.
  static Future<InMemoryNotifyServiceEnvironment> inMemory({
    INotifyRepository? repository,
    String serverLabel = 'NotifyServer',
    String subscriberLabel = 'NotifySubscriber',
    String publisherLabel = 'NotifyPublisher',
  }) async {
    final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

    final repo = repository ?? InMemoryNotifyRepository();
    final server = createServer(
      transport: responderTransport,
      repository: repo,
      debugLabel: serverLabel,
    );
    await server.start();

    final callerEndpoint = RpcCallerEndpoint(
      transport: callerTransport,
      debugLabel: subscriberLabel,
    );

    final subscriber = NotifySubscriber.endpoint(callerEndpoint);
    final publisher = NotifyPublisher.endpoint(callerEndpoint);

    return InMemoryNotifyServiceEnvironment(
      server: server,
      subscriber: subscriber,
      publisher: publisher,
      repository: repo,
      callerTransport: callerTransport,
      responderTransport: responderTransport,
    );
  }
}

/// Truly zero-copy in-process environment.
///
/// Publisher and subscriber talk directly to [InMemoryNotifyRepository]
/// — no RPC transport, no serialization, no dart2js type-erasure issues.
/// Use this when publish/subscribe both live in the same Dart isolate and
/// payloads may contain non-serializable objects.
class DirectNotifyServiceEnvironment {
  DirectNotifyServiceEnvironment() : _repo = InMemoryNotifyRepository() {
    publisher = INotifyPublisher.repository(_repo);
    subscriber = INotifySubscriber.repository(_repo);
  }

  final InMemoryNotifyRepository _repo;
  late final INotifyPublisher publisher;
  late final INotifySubscriber subscriber;

  Future<void> dispose() => _repo.dispose();
}

/// Result of [NotifyServiceFactory.inMemory].
class InMemoryNotifyServiceEnvironment {
  InMemoryNotifyServiceEnvironment({
    required this.server,
    required this.subscriber,
    required this.publisher,
    required this.repository,
    required this.callerTransport,
    required this.responderTransport,
  });

  final NotifyServiceServer server;
  final NotifySubscriber subscriber;
  final NotifyPublisher publisher;

  /// The underlying repository — useful for injecting [INotifyPublisher]
  /// or [INotifySubscribeClient] into other components under test.
  final INotifyRepository repository;

  final IRpcTransport callerTransport;
  final IRpcTransport responderTransport;

  Future<void> dispose() async {
    // Close server first: terminates server-streams and closes the transport.
    // Then close subscriber so it sees the streams are already done.
    await server.close();
    await subscriber.dispose();
    // publisher shares the same endpoint as subscriber — already closed above.
  }
}
