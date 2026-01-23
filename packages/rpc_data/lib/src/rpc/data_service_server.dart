// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';

/// Серверная обёртка: содержит endpoint, responder и репозиторий.
class DataServiceServer {
  DataServiceServer({
    required RpcResponderEndpoint endpoint,
    required DataServiceResponder responder,
    required IDataRepository repository,
  }) : _endpoint = endpoint,
       _responder = responder,
       _repository = repository;

  final RpcResponderEndpoint _endpoint;
  final DataServiceResponder _responder;
  final IDataRepository _repository;

  RpcResponderEndpoint get endpoint => _endpoint;
  DataServiceResponder get rawResponder => _responder;
  IDataRepository get repository => _repository;

  Future<void> start() async {
    _endpoint.registerServiceContract(_responder);
    _endpoint.start();
  }

  Future<void> close() async {
    await _endpoint.close();
    await _responder.dispose();
  }
}
