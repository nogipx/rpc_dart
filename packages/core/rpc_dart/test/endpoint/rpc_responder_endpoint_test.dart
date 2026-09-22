// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The request model.
class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  factory TestRequest.fromJson(Map<String, dynamic> json) {
    return TestRequest(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message};
  }
}

/// The response model.
class TestResponse implements IRpcSerializable {
  final String message;

  TestResponse(this.message);

  factory TestResponse.fromJson(Map<String, dynamic> json) {
    return TestResponse(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message};
  }
}

/// The responder contract under test.
final class TestService extends RpcResponderContract {
  final List<String> callLog = [];

  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'UnaryMethod',
      handler: (request, {context}) async {
        callLog.add('UnaryMethod: ${request.message}');
        return TestResponse('Reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'ServerStreamMethod',
      handler: (request, {context}) async* {
        callLog.add('ServerStreamMethod: ${request.message}');
        for (int i = 0; i < 3; i++) {
          yield TestResponse('Reply ${i + 1} to: ${request.message}');
          await Future<void>.delayed(Duration(milliseconds: 1));
        }
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

/// A sub-contract, for the sub-contract registration tests.
final class SubService extends RpcResponderContract {
  final List<String> callLog = [];

  SubService() : super('SubService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'SubUnaryMethod',
      handler: (request, {context}) async {
        callLog.add('SubUnaryMethod: ${request.message}');
        return TestResponse('SubService reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

/// The parent contract.
final class ParentService extends RpcResponderContract {
  final List<String> callLog = [];

  ParentService() : super('ParentService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'ParentMethod',
      handler: (request, {context}) async {
        callLog.add('ParentMethod: ${request.message}');
        return TestResponse('ParentService reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('RpcResponderEndpoint', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late TestService testService;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Register the service under test.
      testService = TestService();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      testService.callLog.clear();
    });

    test('registering a contract works', () {
      // Register the service.
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();

      // The service is registered.
      expect(responderEndpoint.registeredContracts, contains('TestService'));
      expect(
        responderEndpoint.registeredMethods,
        contains('TestService.UnaryMethod'),
      );
      expect(
        responderEndpoint.registeredMethods,
        contains('TestService.ServerStreamMethod'),
      );
    });

    test('registering several contracts works', () {
      // Build and register several services, each on its own.
      final parentService = ParentService();
      final subService = SubService();
      responderEndpoint.registerServiceContract(parentService);
      responderEndpoint.registerServiceContract(subService);
      responderEndpoint.start();

      // Both services are registered.
      expect(responderEndpoint.registeredContracts, contains('ParentService'));
      expect(responderEndpoint.registeredContracts, contains('SubService'));
      expect(
        responderEndpoint.registeredMethods,
        contains('ParentService.ParentMethod'),
      );
      expect(
        responderEndpoint.registeredMethods,
        contains('SubService.SubUnaryMethod'),
      );
    });

    test('a unary request is handled', () async {
      // Register the service.
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();

      // Send the request through the caller.
      final response = await callerEndpoint
          .unaryRequest<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'UnaryMethod',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
            request: TestRequest('Test request'),
          );

      // The answer, and that the handler ran.
      expect(response.message, equals('Reply to: Test request'));
      expect(testService.callLog, contains('UnaryMethod: Test request'));
    });

    test('registering the same service twice throws', () {
      // First registration.
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();

      // The second must fail.
      expect(
        () => responderEndpoint.registerServiceContract(TestService()),
        throwsA(isA<RpcException>()),
      );
    });

    test('looking a method up', () {
      // Register the service.
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();

      // A method that exists.
      responderEndpoint.validateMethodExists(
        'TestService',
        'UnaryMethod',
        RpcMethodType.unaryRequest,
      );

      // A method that does not.
      expect(
        () => responderEndpoint.validateMethodExists(
          'TestService',
          'NonExistentMethod',
          RpcMethodType.unaryRequest,
        ),
        throwsA(isA<RpcException>()),
      );

      // The right name under the wrong method type.
      expect(
        () => responderEndpoint.validateMethodExists(
          'TestService',
          'UnaryMethod',
          RpcMethodType.serverStream,
        ),
        throwsA(isA<RpcException>()),
      );
    });

    test('closing the endpoint clears the registered services', () async {
      // Register the service.
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();
      expect(responderEndpoint.registeredContracts, isNotEmpty);
      expect(responderEndpoint.registeredMethods, isNotEmpty);

      // Close the endpoint.
      await responderEndpoint.close();

      // Contracts and methods are both cleared.
      expect(responderEndpoint.isActive, isFalse);
      expect(responderEndpoint.registeredContracts, isEmpty);
      expect(responderEndpoint.registeredMethods, isEmpty);
    });

    test('a separately registered service is reachable', () async {
      // Register both services separately.
      final parentService = ParentService();
      final subService = SubService();
      responderEndpoint.registerServiceContract(parentService);
      responderEndpoint.registerServiceContract(subService);
      responderEndpoint.start();

      // Call a SubService method.
      final response = await callerEndpoint
          .unaryRequest<TestRequest, TestResponse>(
            serviceName: 'SubService',
            methodName: 'SubUnaryMethod',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
            request: TestRequest('SubService test'),
          );

      // The answer, and that the handler ran.
      expect(response.message, equals('SubService reply to: SubService test'));
      expect(subService.callLog, contains('SubUnaryMethod: SubService test'));
    });

    test('registering without start() works', () {
      // Register a service but do NOT start the endpoint.
      responderEndpoint.registerServiceContract(testService);

      // The service is registered.
      expect(responderEndpoint.registeredContracts, contains('TestService'));

      // The endpoint is alive but not listening.
      expect(responderEndpoint.isActive, isTrue);

      // Note: the warning about an unstarted endpoint only fires when a real
      // message arrives from the transport.
    });

    group('unregisterServiceContract', () {
      test('unregistering a registered service works', () {
        // Register the service.
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.start();

        // The service is registered.
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(
          responderEndpoint.registeredMethods,
          contains('TestService.UnaryMethod'),
        );
        expect(
          responderEndpoint.registeredMethods,
          contains('TestService.ServerStreamMethod'),
        );

        // Unregister the service.
        responderEndpoint.unregisterServiceContract('TestService');

        // The service and its methods are gone.
        expect(
          responderEndpoint.registeredContracts,
          isNot(contains('TestService')),
        );
        expect(
          responderEndpoint.registeredMethods,
          isNot(contains('TestService.UnaryMethod')),
        );
        expect(
          responderEndpoint.registeredMethods,
          isNot(contains('TestService.ServerStreamMethod')),
        );
      });

      test('unregistering one service leaves the others alone', () {
        // Register several services.
        final parentService = ParentService();
        final subService = SubService();
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.registerServiceContract(parentService);
        responderEndpoint.registerServiceContract(subService);
        responderEndpoint.start();

        // Every service is registered.
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(
          responderEndpoint.registeredContracts,
          contains('ParentService'),
        );
        expect(responderEndpoint.registeredContracts, contains('SubService'));

        // Unregister exactly one of them.
        responderEndpoint.unregisterServiceContract('ParentService');

        // Only ParentService is gone.
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(
          responderEndpoint.registeredContracts,
          isNot(contains('ParentService')),
        );
        expect(responderEndpoint.registeredContracts, contains('SubService'));

        // The other services keep their methods.
        expect(
          responderEndpoint.registeredMethods,
          contains('TestService.UnaryMethod'),
        );
        expect(
          responderEndpoint.registeredMethods,
          contains('SubService.SubUnaryMethod'),
        );
        expect(
          responderEndpoint.registeredMethods,
          isNot(contains('ParentService.ParentMethod')),
        );
      });

      test('unregistering a service that was never registered throws', () {
        // Try to unregister a service that does not exist.
        expect(
          () =>
              responderEndpoint.unregisterServiceContract('NonExistentService'),
          throwsA(isA<RpcException>()),
        );
      });

      test('after unregistering, the service can be registered again', () {
        // Register the service.
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.start();

        // The service is registered.
        expect(responderEndpoint.registeredContracts, contains('TestService'));

        // Unregister the service.
        responderEndpoint.unregisterServiceContract('TestService');

        // The service is gone.
        expect(
          responderEndpoint.registeredContracts,
          isNot(contains('TestService')),
        );

        // Register a fresh instance of the same service.
        final newTestService = TestService();
        responderEndpoint.registerServiceContract(newTestService);

        // It is registered again.
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(
          responderEndpoint.registeredMethods,
          contains('TestService.UnaryMethod'),
        );
      });

      test('the endpoint still works after an unregister', () async {
        // Register several services.
        final parentService = ParentService();
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.registerServiceContract(parentService);
        responderEndpoint.start();

        // Unregister one service.
        responderEndpoint.unregisterServiceContract('TestService');

        // The one left still answers.
        final response = await callerEndpoint
            .unaryRequest<TestRequest, TestResponse>(
              serviceName: 'ParentService',
              methodName: 'ParentMethod',
              requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
              responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
              request: TestRequest('After unregister test'),
            );

        expect(
          response.message,
          equals('ParentService reply to: After unregister test'),
        );
        expect(
          parentService.callLog,
          contains('ParentMethod: After unregister test'),
        );
      });

      test('unregistering every service clears every method', () {
        // Register several services.
        final parentService = ParentService();
        final subService = SubService();
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.registerServiceContract(parentService);
        responderEndpoint.registerServiceContract(subService);
        responderEndpoint.start();

        // Every service and method is registered.
        expect(responderEndpoint.registeredContracts, hasLength(3));
        expect(responderEndpoint.registeredMethods, isNotEmpty);

        // Unregister them one by one.
        responderEndpoint.unregisterServiceContract('TestService');
        responderEndpoint.unregisterServiceContract('ParentService');
        responderEndpoint.unregisterServiceContract('SubService');

        // Every contract and method is gone.
        expect(responderEndpoint.registeredContracts, isEmpty);
        expect(responderEndpoint.registeredMethods, isEmpty);
      });

      test('register and unregister both work after start()', () async {
        // Start the endpoint with no services.
        responderEndpoint.start();

        // Register a service AFTER start().
        responderEndpoint.registerServiceContract(testService);

        // It is registered, and it answers.
        expect(responderEndpoint.registeredContracts, contains('TestService'));

        final response = await callerEndpoint
            .unaryRequest<TestRequest, TestResponse>(
              serviceName: 'TestService',
              methodName: 'UnaryMethod',
              requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
              responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
              request: TestRequest('After start test'),
            );

        expect(response.message, equals('Reply to: After start test'));
        expect(testService.callLog, contains('UnaryMethod: After start test'));

        // Unregister it, also after start().
        responderEndpoint.unregisterServiceContract('TestService');

        // The service is gone.
        expect(
          responderEndpoint.registeredContracts,
          isNot(contains('TestService')),
        );

        // Register a different service after the unregister.
        final newService = TestService();
        responderEndpoint.registerServiceContract(newService);

        // The new service answers.
        final newResponse = await callerEndpoint
            .unaryRequest<TestRequest, TestResponse>(
              serviceName: 'TestService',
              methodName: 'UnaryMethod',
              requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
              responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
              request: TestRequest('New service test'),
            );

        expect(newResponse.message, equals('Reply to: New service test'));
        expect(newService.callLog, contains('UnaryMethod: New service test'));
        // And the old one never saw the request.
        expect(
          testService.callLog,
          isNot(contains('UnaryMethod: New service test')),
        );
      });

      test('unregistering releases the resources', () async {
        // A responder holding the kind of resources a real one would.
        final resourceService = ResourceHeavyService();
        responderEndpoint.registerServiceContract(resourceService);
        responderEndpoint.start();

        // The service is registered.
        expect(
          responderEndpoint.registeredContracts,
          contains('ResourceHeavyService'),
        );

        // Call a method that allocates them.
        final response = await callerEndpoint
            .unaryRequest<TestRequest, TestResponse>(
              serviceName: 'ResourceHeavyService',
              methodName: 'CreateResourceIntensiveOperation',
              requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
              responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
              request: TestRequest('setup resources'),
            );

        expect(response.message, contains('resources created'));
        expect(resourceService.isResourcesActive(), isTrue);

        // Unregister: dispose() is called for us.
        responderEndpoint.unregisterServiceContract('ResourceHeavyService');

        // So the resources are released without the test doing it.
        expect(resourceService.isResourcesActive(), isFalse);
        expect(resourceService.activeConnections, equals(0));
      });

      test('unregisterServiceContract() calls dispose()', () async {
        // A responder holding resources.
        final resourceService = ResourceHeavyService();
        responderEndpoint.registerServiceContract(resourceService);
        responderEndpoint.start();

        // Allocate them.
        final response = await callerEndpoint
            .unaryRequest<TestRequest, TestResponse>(
              serviceName: 'ResourceHeavyService',
              methodName: 'CreateResourceIntensiveOperation',
              requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
              responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
              request: TestRequest('setup resources'),
            );

        expect(response.message, contains('resources created'));
        expect(resourceService.isResourcesActive(), isTrue);

        // Unregister: dispose() must run on its own.
        responderEndpoint.unregisterServiceContract('ResourceHeavyService');

        // The resources are released.
        expect(resourceService.isResourcesActive(), isFalse);
        expect(resourceService.activeConnections, equals(0));
      });

      test('close() calls dispose() on every contract', () async {
        // This test needs an endpoint of its own.
        final (newCallerTransport, newResponderTransport) =
            RpcInMemoryTransport.pair();
        final newResponderEndpoint = RpcResponderEndpoint(
          transport: newResponderTransport,
        );
        final newCallerEndpoint = RpcCallerEndpoint(
          transport: newCallerTransport,
        );

        // Register the services that hold resources.
        final resourceService1 = ResourceHeavyService();

        newResponderEndpoint.registerServiceContract(resourceService1);
        newResponderEndpoint.start();

        // Allocate resources in both of them.
        await newCallerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'ResourceHeavyService',
          methodName: 'CreateResourceIntensiveOperation',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('setup resources 1'),
        );

        expect(resourceService1.isResourcesActive(), isTrue);

        // Close the endpoint: dispose() must run for every contract.
        await newResponderEndpoint.close();

        // Every service's resources are released.
        expect(resourceService1.isResourcesActive(), isFalse);
        expect(resourceService1.activeConnections, equals(0));

        // Cleanup.
        await newCallerEndpoint.close();
      });

      test('a dispose() that throws does not break the unregister', () async {
        // A service whose dispose() throws.
        final problematicService = ProblematicDisposeService();
        responderEndpoint.registerServiceContract(problematicService);
        responderEndpoint.start();

        // Unregistering must not propagate that error.
        expect(
          () => responderEndpoint.unregisterServiceContract(
            'ProblematicDisposeService',
          ),
          returnsNormally,
        );

        // And the service is gone regardless.
        expect(
          responderEndpoint.registeredContracts,
          isNot(contains('ProblematicDisposeService')),
        );
      });
    });
  });
}

/// A service standing in for one that holds real resources.
final class ResourceHeavyService extends RpcResponderContract {
  final List<StreamController<void>> _activeStreams = [];
  final Map<String, StreamSubscription<void>> _subscriptions = {};
  final List<Timer> _timers = [];
  int activeConnections = 0;
  bool _resourcesActive = false;

  ResourceHeavyService() : super('ResourceHeavyService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'CreateResourceIntensiveOperation',
      handler: (request, {context}) async {
        // Stand in for allocating them.
        _createFakeResources();
        return TestResponse(
          'resources created - connections: $activeConnections',
        );
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }

  void _createFakeResources() {
    // 1. A few data streams.
    for (int i = 0; i < 3; i++) {
      final controller = StreamController<String>.broadcast();
      _activeStreams.add(controller);

      // Stand in for subscribing to an outside stream.
      final subscription = Stream.periodic(
        Duration(seconds: 1),
        (count) => 'data_$count',
      ).listen(controller.add);
      _subscriptions['stream_$i'] = subscription;
    }

    // 2. Timers.
    for (int i = 0; i < 2; i++) {
      final timer = Timer.periodic(Duration(seconds: 2), (timer) {
        activeConnections++;
      });
      _timers.add(timer);
    }

    // 3. Stand in for opening database or service connections.
    activeConnections = 5;
    _resourcesActive = true;
  }

  bool isResourcesActive() => _resourcesActive;

  /// dispose() is overridden to release everything above.
  @override
  void dispose() {
    // Close the streams.
    for (final controller in _activeStreams) {
      controller.close();
    }
    _activeStreams.clear();

    // Cancel the subscriptions.
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();

    // Cancel the timers.
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();

    // Close the connections.
    activeConnections = 0;
    _resourcesActive = false;

    // Required: call the parent dispose().
    super.dispose();
  }

  /// Releases the resources by hand, for the compatibility tests.
  void manualCleanup() {
    dispose();
  }
}

/// A service whose dispose() throws, for the error-handling test.
final class ProblematicDisposeService extends RpcResponderContract {
  ProblematicDisposeService() : super('ProblematicDisposeService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'TestMethod',
      handler: (request, {context}) async {
        return TestResponse('test response');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }

  @override
  void dispose() {
    // The failure this service exists to produce.
    throw Exception('failed to release resources');
  }
}
