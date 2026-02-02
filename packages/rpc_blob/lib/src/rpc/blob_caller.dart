import 'package:rpc_dart/rpc_dart.dart';

import 'blob_contract.dart';

class BlobServiceCaller extends BlobServiceContractCaller {
  BlobServiceCaller({
    required RpcCallerEndpoint endpoint,
    required RpcDataTransferMode transferMode,
    String? serviceNameOverride,
  }) : super(
         endpoint,
         serviceNameOverride: serviceNameOverride,
         dataTransferMode: transferMode,
       );
}
