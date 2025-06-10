// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'base_processor.dart';

part 'bidirectional/caller.dart';
part 'bidirectional/responder.dart';

part 'client/caller.dart';
part 'client/responder.dart';

part 'server/caller.dart';
part 'server/responder.dart';

part 'unary/caller.dart';
part 'unary/responder.dart';

abstract interface class IRpcResponder {
  int get id;
}
