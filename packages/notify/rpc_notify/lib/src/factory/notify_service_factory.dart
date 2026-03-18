// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import '../client/i_notify_publisher.dart';
import '../client/i_notify_subscriber.dart';
import '../client/notify_publisher.dart';
import '../client/notify_subscriber.dart';
import '../contract/notify_contract.dart';
import '../contract/notify_publish_contract.dart';
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
        subscriber: INotifySubscriber.repository(repo),
      ),
      publishResponder: NotifyPublishResponder(
        publisher: INotifyPublisher.repository(repo),
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
    return NotifySubscriber(endpoint, NotifySubscribeContractCaller(endpoint));
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
    return NotifyPublisher(endpoint, NotifyPublishContractCaller(endpoint));
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

    final subscriber = NotifySubscriber(
      callerEndpoint,
      NotifySubscribeContractCaller(callerEndpoint),
    );
    final publisher = NotifyPublisher(
      callerEndpoint,
      NotifyPublishContractCaller(callerEndpoint),
    );

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
