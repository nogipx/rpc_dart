// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('GrpcHealthServiceStatus', () {
    late GrpcHealthServiceStatus status;

    setUp(() {
      status = GrpcHealthServiceStatus();
    });

    tearDown(() {
      status.dispose();
    });

    test('returns null for unregistered service', () {
      expect(status.getStatus('UnknownService'), isNull);
    });

    test('setStatus and getStatus round-trip', () {
      status.setStatus('', GrpcServingStatus.serving);
      expect(status.getStatus(''), equals(GrpcServingStatus.serving));

      status.setStatus('MyService', GrpcServingStatus.notServing);
      expect(
          status.getStatus('MyService'), equals(GrpcServingStatus.notServing));
    });

    test('clearStatus removes the service', () {
      status.setStatus('Svc', GrpcServingStatus.serving);
      status.clearStatus('Svc');
      expect(status.getStatus('Svc'), isNull);
    });

    test('clearAll removes all services', () {
      status.setStatus('A', GrpcServingStatus.serving);
      status.setStatus('B', GrpcServingStatus.notServing);
      status.clearAll();
      expect(status.getStatus('A'), isNull);
      expect(status.getStatus('B'), isNull);
    });

    test('changes stream emits on setStatus', () async {
      final events = <(String, GrpcServingStatus)>[];
      final sub = status.changes.listen(events.add);

      status.setStatus('Svc', GrpcServingStatus.serving);
      status.setStatus('Svc', GrpcServingStatus.notServing);

      await Future.delayed(Duration.zero);

      expect(events, [
        ('Svc', GrpcServingStatus.serving),
        ('Svc', GrpcServingStatus.notServing),
      ]);

      await sub.cancel();
    });

    test('changes stream emits serviceUnknown on clearStatus', () async {
      final events = <(String, GrpcServingStatus)>[];
      final sub = status.changes.listen(events.add);

      status.setStatus('Svc', GrpcServingStatus.serving);
      status.clearStatus('Svc');

      await Future.delayed(Duration.zero);

      expect(events.last, ('Svc', GrpcServingStatus.serviceUnknown));

      await sub.cancel();
    });
  });

  group('GrpcHealthCheckRequest/Response serialization', () {
    test('request round-trip via codec', () {
      final request = GrpcHealthCheckRequest(service: 'TestService');
      final codec = GrpcHealthCheckRequest.codec;

      final bytes = codec.serialize(request);
      final decoded = codec.deserialize(bytes);

      expect(decoded.service, equals('TestService'));
    });

    test('request with empty service', () {
      final request = GrpcHealthCheckRequest();
      final codec = GrpcHealthCheckRequest.codec;

      final bytes = codec.serialize(request);
      final decoded = codec.deserialize(bytes);

      expect(decoded.service, equals(''));
    });

    test('response round-trip via codec', () {
      final response = GrpcHealthCheckResponse(
        status: GrpcServingStatus.serving,
      );
      final codec = GrpcHealthCheckResponse.codec;

      final bytes = codec.serialize(response);
      final decoded = codec.deserialize(bytes);

      expect(decoded.status, equals(GrpcServingStatus.serving));
    });

    test('response round-trip for all statuses', () {
      final codec = GrpcHealthCheckResponse.codec;

      for (final status in GrpcServingStatus.values) {
        final response = GrpcHealthCheckResponse(status: status);
        final bytes = codec.serialize(response);
        final decoded = codec.deserialize(bytes);
        expect(decoded.status, equals(status));
      }
    });
  });

  group('GrpcServingStatus', () {
    test('fromValue maps all known values', () {
      expect(GrpcServingStatus.fromValue(0), GrpcServingStatus.unknown);
      expect(GrpcServingStatus.fromValue(1), GrpcServingStatus.serving);
      expect(GrpcServingStatus.fromValue(2), GrpcServingStatus.notServing);
      expect(GrpcServingStatus.fromValue(3), GrpcServingStatus.serviceUnknown);
    });

    test('fromValue defaults to unknown for invalid values', () {
      expect(GrpcServingStatus.fromValue(99), GrpcServingStatus.unknown);
      expect(GrpcServingStatus.fromValue(-1), GrpcServingStatus.unknown);
    });
  });

  group('GrpcHealthCheckContract integration', () {
    late GrpcHealthServiceStatus healthStatus;
    late RpcCallerEndpoint caller;
    late RpcResponderEndpoint responder;

    setUp(() {
      healthStatus = GrpcHealthServiceStatus();
      final (clientTransport, serverTransport) =
          RpcChannelTransport.memoryPair();

      caller = RpcCallerEndpoint(transport: clientTransport);
      responder = RpcResponderEndpoint(transport: serverTransport);

      responder.registerServiceContract(
        GrpcHealthCheckContract(healthStatus),
      );
      responder.start();
    });

    tearDown(() async {
      await caller.close();
      await responder.close();
      healthStatus.dispose();
    });

    test('Check returns serving for registered service', () async {
      healthStatus.setStatus('', GrpcServingStatus.serving);

      final response = await caller
          .unaryRequest<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
        serviceName: GrpcHealthCheckContract.grpcServiceName,
        methodName: 'Check',
        requestCodec: GrpcHealthCheckRequest.codec,
        responseCodec: GrpcHealthCheckResponse.codec,
        request: GrpcHealthCheckRequest(service: ''),
      );

      expect(response.status, equals(GrpcServingStatus.serving));
    });

    test('Check returns notServing for unhealthy service', () async {
      healthStatus.setStatus('MySvc', GrpcServingStatus.notServing);

      final response = await caller
          .unaryRequest<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
        serviceName: GrpcHealthCheckContract.grpcServiceName,
        methodName: 'Check',
        requestCodec: GrpcHealthCheckRequest.codec,
        responseCodec: GrpcHealthCheckResponse.codec,
        request: GrpcHealthCheckRequest(service: 'MySvc'),
      );

      expect(response.status, equals(GrpcServingStatus.notServing));
    });

    test('Check returns serviceUnknown for unregistered service', () async {
      final response = await caller
          .unaryRequest<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
        serviceName: GrpcHealthCheckContract.grpcServiceName,
        methodName: 'Check',
        requestCodec: GrpcHealthCheckRequest.codec,
        responseCodec: GrpcHealthCheckResponse.codec,
        request: GrpcHealthCheckRequest(service: 'NoSuchService'),
      );

      expect(response.status, equals(GrpcServingStatus.serviceUnknown));
    });

    test('Watch emits current status then changes', () async {
      healthStatus.setStatus('WatchMe', GrpcServingStatus.serving);

      final responses = <GrpcServingStatus>[];
      final completer = Completer<void>();

      final stream =
          caller.serverStream<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
        serviceName: GrpcHealthCheckContract.grpcServiceName,
        methodName: 'Watch',
        requestCodec: GrpcHealthCheckRequest.codec,
        responseCodec: GrpcHealthCheckResponse.codec,
        request: GrpcHealthCheckRequest(service: 'WatchMe'),
      );

      final sub = stream.listen((r) {
        responses.add(r.status);
        if (responses.length >= 3) {
          completer.complete();
        }
      });

      // Wait for initial status to arrive
      await Future.delayed(Duration(milliseconds: 50));

      // Trigger changes
      healthStatus.setStatus('WatchMe', GrpcServingStatus.notServing);
      await Future.delayed(Duration(milliseconds: 50));
      healthStatus.setStatus('WatchMe', GrpcServingStatus.serving);

      await completer.future.timeout(Duration(seconds: 5));
      await sub.cancel();

      expect(responses[0], equals(GrpcServingStatus.serving));
      expect(responses[1], equals(GrpcServingStatus.notServing));
      expect(responses[2], equals(GrpcServingStatus.serving));
    });

    test('Watch emits serviceUnknown for unregistered then updates', () async {
      final responses = <GrpcServingStatus>[];
      final completer = Completer<void>();

      final stream =
          caller.serverStream<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
        serviceName: GrpcHealthCheckContract.grpcServiceName,
        methodName: 'Watch',
        requestCodec: GrpcHealthCheckRequest.codec,
        responseCodec: GrpcHealthCheckResponse.codec,
        request: GrpcHealthCheckRequest(service: 'NewSvc'),
      );

      final sub = stream.listen((r) {
        responses.add(r.status);
        if (responses.length >= 2) {
          completer.complete();
        }
      });

      await Future.delayed(Duration(milliseconds: 50));

      // Register the service after Watch started
      healthStatus.setStatus('NewSvc', GrpcServingStatus.serving);

      await completer.future.timeout(Duration(seconds: 5));
      await sub.cancel();

      expect(responses[0], equals(GrpcServingStatus.serviceUnknown));
      expect(responses[1], equals(GrpcServingStatus.serving));
    });
  });
}
