// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';
import 'data_contract.dart';

class DataServiceCaller extends DataServiceContractCaller {
  DataServiceCaller({
    required RpcCallerEndpoint endpoint,
    required RpcDataTransferMode transferMode,
    String? serviceNameOverride,
  }) : super(
         endpoint,
         serviceNameOverride: serviceNameOverride,
         dataTransferMode: transferMode,
       );

  /// Удобный helper для постраничного обхода коллекции.
  Future<List<DataRecord>> listAllRecords(
    String collection, {
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  }) async {
    final aggregated = <DataRecord>[];
    String? cursor;
    do {
      final response = await listRecords(
        ListRecordsRequest(
          collection: collection,
          filter: filter,
          sort: sort,
          options: QueryOptions(limit: 50, cursor: cursor),
        ),
        context: context,
      );
      aggregated.addAll(response.records);
      cursor = response.nextCursor;
    } while (cursor != null);
    return aggregated;
  }

  Future<ImportDatabaseResponse> importDatabaseSync(
    Stream<DatabaseChunk> request, {
    RpcContext? context,
  }) async {
    var lastAck = -1;
    int? lastChunkFromError;
    ImportDatabaseResponse? result;
    try {
      await for (final progress in super.importDatabase(
        request,
        context: context,
      )) {
        lastAck = progress.lastChunkIndex;
        if (progress.result != null) {
          result = progress.result;
        }
      }
    } catch (error, stackTrace) {
      lastChunkFromError = lastAck >= 0
          ? lastAck
          : _extractLastChunkIndex(error.toString());
      if (lastChunkFromError != null) {
        Error.throwWithStackTrace(
          ImportResumeException(
            'Import failed, resume with resumeAfterChunk=$lastChunkFromError',
            lastChunkIndex: lastChunkFromError,
            cause: error,
          ),
          stackTrace,
        );
      }
      rethrow;
    }

    if (result != null) {
      return result;
    }
    final resumeIndex = lastAck >= 0 ? lastAck : lastChunkFromError;
    if (resumeIndex != null) {
      throw ImportResumeException(
        'Import interrupted, resume with resumeAfterChunk=$resumeIndex',
        lastChunkIndex: resumeIndex,
      );
    }
    throw ImportResumeException(
      'Import interrupted and no progress was reported',
      lastChunkIndex: lastChunkFromError,
    );
  }
}

int? _extractLastChunkIndex(String message) {
  final match = RegExp(r'lastChunkIndex=(\d+)').firstMatch(message);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
