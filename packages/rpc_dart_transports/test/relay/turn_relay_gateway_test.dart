// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
  });
}
