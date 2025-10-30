import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart_data/rpc_dart_data.dart';

class _BackpressureInMemoryAdapter extends InMemoryStorageAdapter {
  _BackpressureInMemoryAdapter({this.forcedChunkSize = 1});

  final List<Completer<void>> _gates = <Completer<void>>[];
  final int forcedChunkSize;

  int get pendingChunks => _gates.length;

  void allowNextChunk() {
    if (_gates.isEmpty) {
      throw StateError('No pending chunk requests to release');
    }
    _gates.removeAt(0).complete();
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) async* {
    final records = await readCollection(collection);
    if (records.isEmpty) {
      return;
    }
    final effectiveChunkSize = forcedChunkSize < 1 ? 1 : forcedChunkSize;
    for (var offset = 0;
        offset < records.length;
        offset += effectiveChunkSize) {
      final gate = Completer<void>();
      _gates.add(gate);
      print('awaiting gate for chunk starting at ' + offset.toString());
      await gate.future;
      final end = (offset + effectiveChunkSize) < records.length
          ? offset + effectiveChunkSize
          : records.length;
      print('yielding chunk ' + offset.toString() + '-' + end.toString());
      yield records.sublist(offset, end);
    }
  }
}

Future<void> main() async {
  final storage = _BackpressureInMemoryAdapter();
  final repository = InMemoryDataRepository(storage: storage);

  final now = DateTime.utc(2024, 1, 1);
  final records = <DataRecord>[];
  for (var i = 0; i < 2; i++) {
    records.add(
      DataRecord(
        id: 'item-' + i.toString(),
        collection: 'controlled',
        payload: {'value': i},
        version: 1,
        createdAt: now.add(Duration(seconds: i)),
        updatedAt: now.add(Duration(seconds: i)),
      ),
    );
  }
  await storage.writeRecords(records);

  final export = await repository.exportDatabase(
    const ExportDatabaseRequest(includePayloadString: false),
  );

  final iterator = export.payloadLines().iterator;

  print('first moveNext: ' + (await iterator.moveNext()).toString());
  print('second moveNext: ' + (await iterator.moveNext()).toString());

  await Future<void>.delayed(Duration.zero);
  print('pending after collection: ' + storage.pendingChunks.toString());

  final stalled = iterator.moveNext().timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => false,
      );
  print('stalled result: ' + (await stalled).toString());

  print('pending before release: ' + storage.pendingChunks.toString());
  storage.allowNextChunk();
  print('third moveNext: ' + (await iterator.moveNext()).toString());
  print('pending after third: ' + storage.pendingChunks.toString());

  await Future<void>.delayed(Duration.zero);
  print('pending before second stall: ' + storage.pendingChunks.toString());
  final stalledAgain = iterator.moveNext().timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => false,
      );
  print('stalledAgain result: ' + (await stalledAgain).toString());

  print('pending before second release: ' + storage.pendingChunks.toString());
  storage.allowNextChunk();
  print('fourth moveNext: ' + (await iterator.moveNext()).toString());
  print('fifth moveNext: ' + (await iterator.moveNext()).toString());
  print('sixth moveNext: ' + (await iterator.moveNext()).toString());

  await repository.dispose();
}
