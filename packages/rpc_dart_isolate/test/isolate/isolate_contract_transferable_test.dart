// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

void main() {
  group('Rpc contracts with TransferableTypedData over isolate transport', () {
    test('unary zero-copy contract echoes transferable payload', () async {
      final result = await RpcIsolateTransport.spawn(
        entrypoint: transferableContractEntrypoint,
        customParams: const {},
        isolateId: 'contract-transferable',
      );

      final caller = RpcCallerEndpoint(transport: result.transport);

      final bytes = Uint8List.fromList(
        List<int>.generate(512, (index) => index % 256),
      );
      final request = TransferableTypedData.fromList([bytes]);

      final response = await caller
          .unaryRequest<TransferableTypedData, TransferableTypedData>(
        serviceName: TransferableEchoContract.serviceNameStatic,
        methodName: TransferableEchoContract.methodName,
        request: request,
      );

      final materialized = response.materialize().asUint8List();
      expect(materialized, orderedEquals(bytes));

      await caller.close();
      result.kill();
    });
  });
}

@pragma('vm:entry-point')
void transferableContractEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final endpoint = RpcResponderEndpoint(
    transport: transport,
    debugLabel: 'transferable-responder',
  );

  final contract = TransferableEchoContract();
  contract.setup();
  endpoint.registerServiceContract(contract);
  endpoint.start();
}

final class TransferableEchoContract extends RpcResponderContract {
  static const serviceNameStatic = 'transferable.Echo';
  static const methodName = 'Echo';

  TransferableEchoContract()
      : super(serviceNameStatic, dataTransferMode: RpcDataTransferMode.auto);

  @override
  void setup() {
    addUnaryMethod<TransferableTypedData, TransferableTypedData>(
      methodName: methodName,
      handler: (payload, {RpcContext? context}) async {
        final bytes = payload.materialize().asUint8List();
        return TransferableTypedData.fromList([bytes]);
      },
      // zero-copy: omit codecs
    );
  }
}
