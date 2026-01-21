// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import '../adapters/_index.dart';
import '../change_journal.dart';
import '../models.dart';
import '../rpc/data_contract.dart';
import '../schema/schema_validation.dart';

part 'base_data_repository.dart';
part 'i_data_repository.dart';
part 'in_memory_data_repository.dart';
