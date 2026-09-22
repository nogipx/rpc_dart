// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

/// Using dispose() in RPC responders.
///
/// Shows:
/// - owning resources in a responder (database connections, timers, streams)
/// - automatic cleanup when a contract is unregistered
/// - automatic cleanup when the endpoint closes
/// - how to implement dispose() in your own responders
/// - handling errors raised inside dispose()
///
/// The rules:
/// 1. dispose() runs automatically on unregisterServiceContract()
/// 2. dispose() runs automatically when the endpoint is closed
/// 3. an error in dispose() does not interrupt anything else
/// 4. an override must call super.dispose()
/// 5. check a resource's state before releasing it
void main() async {
  print('Using dispose() in RPC responders\n');
  // The transports.
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
  final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);
  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);
  // Services that own resources.
  final databaseService = DatabaseService();
  final cachingService = CachingService();
  final analyticsService = AnalyticsService();
  print('Registering the services');
  responderEndpoint.registerServiceContract(databaseService);
  responderEndpoint.registerServiceContract(cachingService);
  responderEndpoint.registerServiceContract(analyticsService);
  responderEndpoint.start();
  // Exercise them.
  print('\nExercising the services');
  // Initialise the resources (zero-copy).
  await callerEndpoint.unaryRequest<ResourceRequest, ResourceResponse>(
    serviceName: 'DatabaseService',
    methodName: 'initialize',
    request: ResourceRequest('init database'),
  );
  await callerEndpoint.unaryRequest<ResourceRequest, ResourceResponse>(
    serviceName: 'CachingService',
    methodName: 'initialize',
    request: ResourceRequest('setup cache'),
  );
  print('All services initialised and running');
  // What each one holds.
  print('\nResource state:');
  print('  Database connections: ${databaseService.activeConnections}');
  print('  Cache size: ${cachingService.cacheSize}');
  print('  Analytics timers: ${analyticsService.activeTimers}');
  // Unregister one service.
  print('\nUnregistering DatabaseService (dispose() runs automatically)');
  responderEndpoint.unregisterServiceContract('DatabaseService');
  print('State after unregistering:');
  print(
    '  Database connections: ${databaseService.activeConnections} '
    '(should be 0)',
  );
  print('  Cache size: ${cachingService.cacheSize} (unchanged)');
  print('  Analytics timers: ${analyticsService.activeTimers} (unchanged)');
  // Close the endpoint: every remaining dispose() runs.
  print('\nClosing the endpoint (dispose() runs for every remaining service)');
  await responderEndpoint.close();
  print('Final resource state:');
  print('  Database connections: ${databaseService.activeConnections}');
  print('  Cache size: ${cachingService.cacheSize} (should be 0)');
  print('  Analytics timers: ${analyticsService.activeTimers} (should be 0)');
  await callerEndpoint.close();
  print('\nExample finished. Every resource is released.');
}

// =============================================================================
// The models (zero-copy)
// =============================================================================
class ResourceRequest {
  final String operation;
  ResourceRequest(this.operation);
}

class ResourceResponse {
  final String result;
  final bool success;
  ResourceResponse(this.result, {this.success = true});
}

// =============================================================================
// 1: a service holding database connections
// =============================================================================
final class DatabaseService extends RpcResponderContract {
  // Stand-ins for real database connections.
  final List<StreamController<void>> _connections = [];
  final List<StreamSubscription<void>> _subscriptions = [];
  int activeConnections = 0;
  DatabaseService() : super('DatabaseService');
  @override
  void setup() {
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'initialize',
      handler: _initializeDatabase,
    );
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'query',
      handler: _executeQuery,
    );
  }

  Future<ResourceResponse> _initializeDatabase(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    print('  [Database] opening connections');
    // Stand in for opening real connections.
    for (int i = 0; i < 3; i++) {
      final controller = StreamController<String>();
      _connections.add(controller);
      // Stand in for subscribing to database events.
      final subscription = controller.stream.listen((data) {
        // Handle the data.
      });
      _subscriptions.add(subscription);
      activeConnections++;
    }
    print('  [Database] $activeConnections connections open');
    return ResourceResponse(
      'Database initialized with $activeConnections connections',
    );
  }

  Future<ResourceResponse> _executeQuery(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    if (activeConnections == 0) {
      return ResourceResponse(
        'No database connections available',
        success: false,
      );
    }
    return ResourceResponse('Query executed successfully');
  }

  /// Releases the database resources.
  @override
  void dispose() {
    print('  [Database] releasing resources');
    // Cancel every subscription.
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    // Close every connection.
    for (final connection in _connections) {
      connection.close();
    }
    _connections.clear();
    activeConnections = 0;
    print('  [Database] every connection closed');
    // Required: call the parent dispose().
    super.dispose();
  }
}

// =============================================================================
// 2: a caching service
// =============================================================================
final class CachingService extends RpcResponderContract {
  // A stand-in cache.
  final Map<String, dynamic> _cache = {};
  Timer? _cleanupTimer;
  int cacheSize = 0;
  CachingService() : super('CachingService');
  @override
  void setup() {
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'initialize',
      handler: _initializeCache,
    );
  }

  Future<ResourceResponse> _initializeCache(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    print('  [Cache] filling the cache');
    // Fill it with test data.
    for (int i = 0; i < 100; i++) {
      _cache['key_$i'] = 'value_$i';
      cacheSize++;
    }
    // Start the eviction timer.
    _cleanupTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      print('  [Cache] periodic eviction');
    });
    print('  [Cache] $cacheSize entries');
    return ResourceResponse('Cache initialized with $cacheSize items');
  }

  /// Releases the cache resources.
  @override
  void dispose() {
    print('  [Cache] releasing resources');
    // Stop the eviction timer.
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    // Drop the cache.
    _cache.clear();
    cacheSize = 0;
    print('  [Cache] cleared, timer stopped');
    // Required: call the parent dispose().
    super.dispose();
  }
}

// =============================================================================
// 3: an analytics service holding several kinds of resource
// =============================================================================
final class AnalyticsService extends RpcResponderContract {
  // Stand-ins for analytics resources.
  final List<Timer> _timers = [];
  final List<StreamController<void>> _eventStreams = [];
  int activeTimers = 0;
  AnalyticsService() : super('AnalyticsService');
  @override
  void setup() {
    addUnaryMethod<ResourceRequest, ResourceResponse>(
      methodName: 'initialize',
      handler: _initializeAnalytics,
    );
    // This one initialises itself at setup.
    _autoInitialize();
  }

  void _autoInitialize() {
    print('  [Analytics] initialising');
    // Timers that collect metrics.
    for (int i = 0; i < 2; i++) {
      final timer = Timer.periodic(Duration(seconds: 10), (timer) {
        // Collect the metrics.
      });
      _timers.add(timer);
      activeTimers++;
    }
    // Event streams.
    for (int i = 0; i < 2; i++) {
      final controller = StreamController<Map<String, dynamic>>.broadcast();
      _eventStreams.add(controller);
    }
    print(
      '  [Analytics] $activeTimers timers and ${_eventStreams.length} '
      'event streams',
    );
  }

  Future<ResourceResponse> _initializeAnalytics(
    ResourceRequest request, {
    RpcContext? context,
  }) async {
    return ResourceResponse(
      'Analytics already initialized with $activeTimers timers',
    );
  }

  /// Releases the analytics resources.
  @override
  void dispose() {
    print('  [Analytics] releasing resources');
    // Stop every timer.
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    activeTimers = 0;
    // Close the event streams.
    for (final controller in _eventStreams) {
      controller.close();
    }
    _eventStreams.clear();
    print('  [Analytics] timers stopped, streams closed');
    // Required: call the parent dispose().
    super.dispose();
  }
}
