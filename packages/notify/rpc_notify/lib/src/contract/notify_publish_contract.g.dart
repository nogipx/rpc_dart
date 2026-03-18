// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notify_publish_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class NotifyPublishContractNames {
  const NotifyPublishContractNames._();
  static const service = 'NotifyPublishService';
  static String instance(String suffix) => '$service\_$suffix';
  static const publish = 'publish';
  static const publishTo = 'publishTo';
}

class NotifyPublishContractCodecs {
  const NotifyPublishContractCodecs._();
  static const codecNotifyPublishRequest =
      RpcCodec<NotifyPublishRequest>.withDecoder(NotifyPublishRequest.fromJson);
  static const codecNotifyPublishResponse =
      RpcCodec<NotifyPublishResponse>.withDecoder(
        NotifyPublishResponse.fromJson,
      );
  static const codecNotifyPublishToRequest =
      RpcCodec<NotifyPublishToRequest>.withDecoder(
        NotifyPublishToRequest.fromJson,
      );
}

class NotifyPublishContractCaller extends RpcCallerContract
    implements INotifyPublishContract {
  NotifyPublishContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? NotifyPublishContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<NotifyPublishResponse> publish(
    NotifyPublishRequest request, {
    RpcContext? context,
  }) {
    return callUnary<NotifyPublishRequest, NotifyPublishResponse>(
      methodName: NotifyPublishContractNames.publish,
      requestCodec: NotifyPublishContractCodecs.codecNotifyPublishRequest,
      responseCodec: NotifyPublishContractCodecs.codecNotifyPublishResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<NotifyPublishResponse> publishTo(
    NotifyPublishToRequest request, {
    RpcContext? context,
  }) {
    return callUnary<NotifyPublishToRequest, NotifyPublishResponse>(
      methodName: NotifyPublishContractNames.publishTo,
      requestCodec: NotifyPublishContractCodecs.codecNotifyPublishToRequest,
      responseCodec: NotifyPublishContractCodecs.codecNotifyPublishResponse,
      request: request,
      context: context,
    );
  }
}

abstract class NotifyPublishContractResponder extends RpcResponderContract
    implements INotifyPublishContract {
  NotifyPublishContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? NotifyPublishContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<NotifyPublishRequest, NotifyPublishResponse>(
      methodName: NotifyPublishContractNames.publish,
      handler: publish,
      description: 'Broadcast an event to all subscribers of a topic',
      requestCodec: NotifyPublishContractCodecs.codecNotifyPublishRequest,
      responseCodec: NotifyPublishContractCodecs.codecNotifyPublishResponse,
    );
    addUnaryMethod<NotifyPublishToRequest, NotifyPublishResponse>(
      methodName: NotifyPublishContractNames.publishTo,
      handler: publishTo,
      description: 'Deliver an event to a specific client on a topic',
      requestCodec: NotifyPublishContractCodecs.codecNotifyPublishToRequest,
      responseCodec: NotifyPublishContractCodecs.codecNotifyPublishResponse,
    );
  }
}
