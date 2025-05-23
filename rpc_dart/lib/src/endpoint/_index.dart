// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async'
    show
        Completer,
        Future,
        Stream,
        StreamController,
        StreamSubscription,
        Timer,
        TimeoutException;
import 'dart:math';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';

part 'impl/_message_handler.dart';
part 'impl/_request_manager.dart';
part 'impl/_stream_manager.dart';
part 'impl/_middleware_executor.dart';
part 'impl/rpc_engine_impl.dart';
part 'impl/rpc_endpoint_impl.dart';
part 'impl/rpc_method_registry.dart';

part 'interfaces/i_rpc_engine.dart';
part 'interfaces/i_rpc_endpoint.dart';
part 'interfaces/i_rpc_method_registry.dart';

part 'rpc_endpoint.dart';

final _random = Random();
String _defaultUniqueIdGenerator([String? prefix]) {
  // Текущее время в миллисекундах + случайное число
  return '${prefix != null ? '${prefix}_' : ''}${DateTime.now().toUtc().toIso8601String()}_${_random.nextInt(1000000)}';
}

typedef RpcUniqueIdGenerator = String Function([String? prefix]);
