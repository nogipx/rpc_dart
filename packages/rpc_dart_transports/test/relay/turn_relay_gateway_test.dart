// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart' as io;

void main() {
  group('TurnRelayGateway', () {
    late TurnRelayServer relayServer;
    late TurnRelayGatewayServer gatewayServer;

    setUp(() async {
      relayServer = TurnRelayServer(
        bindAddress: io.InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await relayServer.start();

      gatewayServer = TurnRelayGatewayServer(
        bindAddress: io.InternetAddress.loopbackIPv4,
        bindPort: 0,
        relayAddress: relayServer.bindAddress,
        relayPort: relayServer.port,
      );

      await gatewayServer.start();
    });

    tearDown(() async {
      await gatewayServer.stop();
      await relayServer.stop();
    });

    test('tcp client exchanges ping/pong with websocket client via relay', () async {
      final tcpClient = await TurnRelayClient.connect(
        serverAddress: relayServer.bindAddress,
        serverPort: relayServer.port,
      );
      addTearDown(tcpClient.close);

      final callerEndpoint = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport.connect(
          Uri.parse('ws://${gatewayServer.bindAddress.address}:${gatewayServer.port}'),
        ),
        debugLabel: 'web-gateway-client',
      );
      addTearDown(callerEndpoint.close);

      final gatewayCaller = TurnRelayGatewayCaller(callerEndpoint);

      final allocation = await gatewayCaller
          .getAllocationInfo()
          .timeout(const Duration(seconds: 2));

      expect(allocation.relayAddress, isNotEmpty);
      expect(allocation.relayPort, greaterThan(0));

      const serviceId = 'web-gateway-client';
      await gatewayCaller.registerService(
        TurnRelayGatewayRegisterServiceRequest(
          serviceId: serviceId,
          description: 'integration-test',
        ),
      );

      final services = await gatewayCaller
          .listServices(serviceId: serviceId)
          .timeout(const Duration(seconds: 2));
      expect(services, isNotEmpty);
      expect(services.first.serviceId, serviceId);
      expect(services.first.relayAddress, allocation.relayAddress);

      final connectRequestFuture = gatewayCaller
          .watchConnectRequests()
          .first
          .timeout(const Duration(seconds: 5));

      final inboundBytesFuture = gatewayCaller
          .watchIncomingBytes()
          .first
          .timeout(const Duration(seconds: 5));

      final tcpInboundFuture = tcpClient.bytes.first.timeout(
            const Duration(seconds: 5),
          );

      await tcpClient.requestPeerConnection(
        peerAddress: io.InternetAddress(allocation.relayAddress),
        peerPort: allocation.relayPort,
        payload: Uint8List.fromList('hello'.codeUnits),
      );

      final connectRequest = await connectRequestFuture;
      expect(connectRequest.peerAddress, tcpClient.relayAddress.address);
      expect(connectRequest.peerPort, tcpClient.relayPort);
      expect(connectRequest.payload, Uint8List.fromList('hello'.codeUnits));

      await gatewayCaller.addPermission(
        TurnRelayGatewayPermissionRequest(
          peerAddress: connectRequest.peerAddress,
          peerPort: connectRequest.peerPort,
        ),
      );

      await gatewayCaller.sendToPeer(
        TurnRelayGatewaySendRequest(
          peerAddress: connectRequest.peerAddress,
          peerPort: connectRequest.peerPort,
          payload: Uint8List.fromList('ping'.codeUnits),
        ),
      );

      final tcpPayload = await tcpInboundFuture;
      expect(String.fromCharCodes(tcpPayload), 'ping');

      await tcpClient.send(
        Uint8List.fromList('pong'.codeUnits),
        peerAddress: io.InternetAddress(allocation.relayAddress),
        peerPort: allocation.relayPort,
      );

      final webPayload = await inboundBytesFuture;
      expect(String.fromCharCodes(webPayload), 'pong');
    });

    test(
        'tcp and websocket clients exchange ping/pong via relay when running in separate isolates',
        () async {
      const timeout = Duration(seconds: 5);

      final webMessages = ReceivePort();
      final webErrors = ReceivePort();
      final webExit = ReceivePort();

      final gatewayUri =
          'ws://${gatewayServer.bindAddress.address}:${gatewayServer.port}';

      final webIsolate = await Isolate.spawn(
        _runWebGatewayClient,
        <Object?>[
          webMessages.sendPort,
          gatewayUri,
          timeout.inMilliseconds,
        ],
        onError: webErrors.sendPort,
        onExit: webExit.sendPort,
      );

      final webErrorSub = webErrors.listen((message) {
        final parts = message as List<Object?>;
        fail('Web isolate error: ${parts[0]}\n${parts[1]}');
      });

      final webIterator = StreamIterator<Object?>(webMessages);

      addTearDown(() async {
        webIsolate.kill(priority: Isolate.immediate);
        await webIterator.cancel();
        await webErrorSub.cancel();
        webMessages.close();
        webErrors.close();
        webExit.close();
      });

      final hasAllocationMessage =
          await webIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasAllocationMessage, isTrue, reason: 'web isolate produced no data');

      final allocationMessage =
          _expectMessage(webIterator.current, expectedType: 'allocation');

      final relayAddress = allocationMessage['relayAddress'] as String;
      final relayPort = allocationMessage['relayPort'] as int;

      final hasServicesMessage =
          await webIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasServicesMessage, isTrue, reason: 'web isolate did not report services');

      final servicesMessage =
          _expectMessage(webIterator.current, expectedType: 'services');
      final servicesPayload = servicesMessage['services'] as List<dynamic>;
      expect(servicesPayload, isNotEmpty);

      final tcpMessages = ReceivePort();
      final tcpErrors = ReceivePort();
      final tcpExit = ReceivePort();

      final tcpIsolate = await Isolate.spawn(
        _runTcpTurnClient,
        <Object?>[
          tcpMessages.sendPort,
          relayServer.bindAddress.address,
          relayServer.port,
          relayAddress,
          relayPort,
          timeout.inMilliseconds,
        ],
        onError: tcpErrors.sendPort,
        onExit: tcpExit.sendPort,
      );

      final tcpErrorSub = tcpErrors.listen((message) {
        final parts = message as List<Object?>;
        fail('TCP isolate error: ${parts[0]}\n${parts[1]}');
      });

      final tcpIterator = StreamIterator<Object?>(tcpMessages);

      addTearDown(() async {
        tcpIsolate.kill(priority: Isolate.immediate);
        await tcpIterator.cancel();
        await tcpErrorSub.cancel();
        tcpMessages.close();
        tcpErrors.close();
        tcpExit.close();
      });

      final hasConnectMessage =
          await webIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasConnectMessage, isTrue, reason: 'web isolate connect stream ended');

      final connectMessage =
          _expectMessage(webIterator.current, expectedType: 'connect');
      expect(connectMessage['peerAddress'], isNotEmpty);
      expect(connectMessage['peerPort'], greaterThan(0));
      expect(
        String.fromCharCodes(connectMessage['payload'] as Uint8List),
        'hello',
      );

      final hasTcpReceived =
          await tcpIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasTcpReceived, isTrue, reason: 'tcp isolate did not report payload');

      final tcpReceived =
          _expectMessage(tcpIterator.current, expectedType: 'received');
      expect(String.fromCharCodes(tcpReceived['payload'] as Uint8List), 'ping');

      final hasWebPayload =
          await webIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasWebPayload, isTrue, reason: 'web isolate did not receive pong');

      final webPayload =
          _expectMessage(webIterator.current, expectedType: 'payload');
      expect(String.fromCharCodes(webPayload['payload'] as Uint8List), 'pong');

      final hasTcpDone =
          await tcpIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasTcpDone, isTrue, reason: 'tcp isolate did not finish');
      _expectMessage(tcpIterator.current, expectedType: 'done');

      final hasWebDone =
          await webIterator.moveNext().timeout(timeout, onTimeout: () => false);
      expect(hasWebDone, isTrue, reason: 'web isolate did not finish');
      _expectMessage(webIterator.current, expectedType: 'done');

      await tcpExit.first.timeout(timeout);
      await webExit.first.timeout(timeout);
    });
  });
}

Map<String, Object?> _expectMessage(
  Object? message, {
  required String expectedType,
}) {
  expect(message, isA<Map<Object?, Object?>>());
  final typed = Map<Object?, Object?>.from(message! as Map<Object?, Object?>);
  expect(typed['type'], expectedType);
  final result = <String, Object?>{};
  typed.forEach((key, value) {
    if (key is! String) {
      fail('Unexpected non-string key: $key');
    }
    result[key] = value;
  });
  return result;
}

Future<void> _runWebGatewayClient(List<Object?> args) async {
  final sendPort = args[0] as SendPort;
  final gatewayUri = args[1] as String;
  final timeout = Duration(milliseconds: args[2] as int);

  final callerEndpoint = RpcCallerEndpoint(
    transport: RpcWebSocketCallerTransport.connect(Uri.parse(gatewayUri)),
    debugLabel: 'web-gateway-client-isolate',
  );
  final gatewayCaller = TurnRelayGatewayCaller(callerEndpoint);

  try {
    final allocation =
        await gatewayCaller.getAllocationInfo().timeout(timeout);
    sendPort.send({
      'type': 'allocation',
      'relayAddress': allocation.relayAddress,
      'relayPort': allocation.relayPort,
    });

    const serviceId = 'web-gateway-client-isolate';
    await gatewayCaller.registerService(
      TurnRelayGatewayRegisterServiceRequest(
        serviceId: serviceId,
        description: 'isolate-test',
      ),
    );

    final services = await gatewayCaller
        .listServices(serviceId: serviceId)
        .timeout(timeout);
    sendPort.send({
      'type': 'services',
      'services': services.map((service) => service.toJson()).toList(),
    });

    final connectRequestFuture =
        gatewayCaller.watchConnectRequests().first.timeout(timeout);
    final inboundBytesFuture =
        gatewayCaller.watchIncomingBytes().first.timeout(timeout);

    final connectRequest = await connectRequestFuture;
    sendPort.send({
      'type': 'connect',
      'peerAddress': connectRequest.peerAddress,
      'peerPort': connectRequest.peerPort,
      'payload': connectRequest.payload,
    });

    await gatewayCaller.addPermission(
      TurnRelayGatewayPermissionRequest(
        peerAddress: connectRequest.peerAddress,
        peerPort: connectRequest.peerPort,
      ),
    );

    await gatewayCaller.sendToPeer(
      TurnRelayGatewaySendRequest(
        peerAddress: connectRequest.peerAddress,
        peerPort: connectRequest.peerPort,
        payload: Uint8List.fromList('ping'.codeUnits),
      ),
    );

    final inboundPayload = await inboundBytesFuture;
    sendPort.send({
      'type': 'payload',
      'payload': inboundPayload,
    });
  } finally {
    await callerEndpoint.close();
    sendPort.send({'type': 'done'});
  }
}

Future<void> _runTcpTurnClient(List<Object?> args) async {
  final sendPort = args[0] as SendPort;
  final serverAddress = args[1] as String;
  final serverPort = args[2] as int;
  final relayAddress = args[3] as String;
  final relayPort = args[4] as int;
  final timeout = Duration(milliseconds: args[5] as int);

  final client = await TurnRelayClient.connect(
    serverAddress: io.InternetAddress(serverAddress),
    serverPort: serverPort,
  );

  try {
    final inboundFuture = client.bytes.first.timeout(timeout);

    await client.requestPeerConnection(
      peerAddress: io.InternetAddress(relayAddress),
      peerPort: relayPort,
      payload: Uint8List.fromList('hello'.codeUnits),
    );

    final inboundPayload = await inboundFuture;
    sendPort.send({
      'type': 'received',
      'payload': inboundPayload,
    });

    await client.send(
      Uint8List.fromList('pong'.codeUnits),
      peerAddress: io.InternetAddress(relayAddress),
      peerPort: relayPort,
    );
  } finally {
    await client.close();
    sendPort.send({'type': 'done'});
  }
}
