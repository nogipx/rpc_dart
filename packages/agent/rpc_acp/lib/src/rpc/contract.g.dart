// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class AcpTunnelNames {
  const AcpTunnelNames._();
  static const service = 'AcpTunnel';
  static String instance(String suffix) => '$service\_$suffix';
  static const exchange = 'exchange';
}

class AcpTunnelCodecs {
  const AcpTunnelCodecs._();
  static const codecAcpRpcMessage = RpcCodec<AcpRpcMessage>(
    AcpRpcMessage.fromJson,
  );
}

abstract class AcpTunnelPeer extends RpcPeerContract implements IAcpTunnel {
  AcpTunnelPeer(
    RpcPeerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? AcpTunnelNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
         callerDataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addBidirectionalMethod<AcpRpcMessage, AcpRpcMessage>(
      methodName: AcpTunnelNames.exchange,
      handler: onExchange,
      requestCodec: AcpTunnelCodecs.codecAcpRpcMessage,
      responseCodec: AcpTunnelCodecs.codecAcpRpcMessage,
    );
  }

  @override
  Stream<AcpRpcMessage> exchange(
    Stream<AcpRpcMessage> requests, {
    RpcContext? context,
  }) {
    return callBidirectionalStream<AcpRpcMessage, AcpRpcMessage>(
      methodName: AcpTunnelNames.exchange,
      requestCodec: AcpTunnelCodecs.codecAcpRpcMessage,
      responseCodec: AcpTunnelCodecs.codecAcpRpcMessage,
      requests: requests,
      context: context,
    );
  }

  Stream<AcpRpcMessage> onExchange(
    Stream<AcpRpcMessage> requests, {
    RpcContext? context,
  });
}

class AcpTunnelPeerCaller extends RpcPeerContract implements IAcpTunnel {
  AcpTunnelPeerCaller(
    RpcPeerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? AcpTunnelNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
         callerDataTransferMode: dataTransferMode,
       );

  @override
  void setup() {}

  @override
  Stream<AcpRpcMessage> exchange(
    Stream<AcpRpcMessage> requests, {
    RpcContext? context,
  }) {
    return callBidirectionalStream<AcpRpcMessage, AcpRpcMessage>(
      methodName: AcpTunnelNames.exchange,
      requestCodec: AcpTunnelCodecs.codecAcpRpcMessage,
      responseCodec: AcpTunnelCodecs.codecAcpRpcMessage,
      requests: requests,
      context: context,
    );
  }
}
