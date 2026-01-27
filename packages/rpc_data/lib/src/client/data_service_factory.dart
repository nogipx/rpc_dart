// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';

/// Утилиты для создания сервиса/клиента.
class DataServiceFactory {
  const DataServiceFactory._();

  /// Создать серверную часть поверх произвольного транспорта и репозитория.
  static DataServiceServer createServer({
    required IRpcTransport transport,
    required IDataRepository repository,
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
    String debugLabel = 'DataServiceServer',
    int importAckEveryChunks = 32,
  }) {
    return DataServiceServer(
      endpoint: RpcResponderEndpoint(
        transport: transport,
        debugLabel: debugLabel,
      ),
      responder: DataServiceResponder(
        repository: repository,
        transferMode: transferMode,
        importAckEveryChunks: importAckEveryChunks,
      ),
      repository: repository,
    );
  }

  /// Создать клиентскую часть.
  static DataServiceClient createClient({
    required IRpcTransport transport,
    RpcDataTransferMode transferMode = RpcDataTransferMode.codec,
    String debugLabel = 'DataServiceClient',
  }) {
    final endpoint = RpcCallerEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    final caller = DataServiceCaller(
      endpoint: endpoint,
      transferMode: transferMode,
    );
    return DataServiceClient(endpoint, caller);
  }

  /// Полный in-memory стенд: transport pair + репозиторий.
  static Future<InMemoryDataServiceEnvironment> inMemory({
    IDataRepository? repository,
    String serverLabel = 'DataResponder',
    String clientLabel = 'DataCaller',
  }) async {
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    final repo = repository ?? InMemoryDataRepository();
    final server = createServer(
      transport: serverTransport,
      repository: repo,
      debugLabel: serverLabel,
      transferMode: RpcDataTransferMode.zeroCopy,
    );
    await server.start();
    final client = createClient(
      transport: clientTransport,
      debugLabel: clientLabel,
      transferMode: RpcDataTransferMode.zeroCopy,
    );
    return InMemoryDataServiceEnvironment(
      client: client,
      server: server,
      clientTransport: clientTransport,
      serverTransport: serverTransport,
    );
  }
}

/// Результат helper-а для быстрого развёртывания in-memory окружения.
class InMemoryDataServiceEnvironment {
  InMemoryDataServiceEnvironment({
    required this.client,
    required this.server,
    required this.clientTransport,
    required this.serverTransport,
  });

  final DataServiceClient client;
  final DataServiceServer server;
  final IRpcTransport clientTransport;
  final IRpcTransport serverTransport;

  Future<void> dispose() async {
    await client.close();
    await server.close();
  }
}
