// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notify_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class NotifySubscribeContractNames {
  const NotifySubscribeContractNames._();
  static const service = 'NotifySubscribeService';
  static String instance(String suffix) => '$service\_$suffix';
  static const subscribe = 'subscribe';
}

class NotifySubscribeContractCodecs {
  const NotifySubscribeContractCodecs._();
  static const codecNotifyEvent = RpcCodec<NotifyEvent>.withDecoder(
    NotifyEvent.fromJson,
  );
  static const codecNotifySubscribeRequest =
      RpcCodec<NotifySubscribeRequest>.withDecoder(
        NotifySubscribeRequest.fromJson,
      );
}

class NotifySubscribeContractCaller extends RpcCallerContract
    implements INotifySubscribeContract {
  NotifySubscribeContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? NotifySubscribeContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Stream<NotifyEvent> subscribe(
    NotifySubscribeRequest request, {
    RpcContext? context,
  }) {
    return callServerStream<NotifySubscribeRequest, NotifyEvent>(
      methodName: NotifySubscribeContractNames.subscribe,
      requestCodec: NotifySubscribeContractCodecs.codecNotifySubscribeRequest,
      responseCodec: NotifySubscribeContractCodecs.codecNotifyEvent,
      request: request,
      context: context,
    );
  }
}

abstract class NotifySubscribeContractResponder extends RpcResponderContract
    implements INotifySubscribeContract {
  NotifySubscribeContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? NotifySubscribeContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addServerStreamMethod<NotifySubscribeRequest, NotifyEvent>(
      methodName: NotifySubscribeContractNames.subscribe,
      handler: subscribe,
      description: 'Server-stream of NotifyEvent for the requested topic',
      requestCodec: NotifySubscribeContractCodecs.codecNotifySubscribeRequest,
      responseCodec: NotifySubscribeContractCodecs.codecNotifyEvent,
    );
  }
}
