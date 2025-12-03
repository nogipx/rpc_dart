import 'dart:async';

import 'package:rpc_dart_data/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('DataCommand', () {
    test('serializes/deserializes via JSON', () {
      final command = DataCommand(
        commandId: 'command-1',
        sessionId: 'session-1',
        type: DataCommandType.patch,
        payload: {'id': 'task-1'},
        issuedAt: DateTime.utc(2024, 1, 1),
      );

      final json = command.toJson();
      final deserialised = DataCommand.fromJson(json);
      expect(deserialised, equals(command));
    });
  });

  group('DataRecord', () {
    final created = DateTime.utc(2024, 1, 1);
    final record = DataRecord(
      id: 'record-1',
      collection: 'tasks',
      payload: {'value': 1},
      version: 1,
      createdAt: created,
      updatedAt: created,
    );

    test('copyWith preserves immutability', () {
      final copy = record.copyWith(
        payload: {'value': 2},
        version: 2,
        updatedAt: created.add(const Duration(days: 1)),
      );

      expect(copy.id, record.id);
      expect(copy.collection, record.collection);
      expect(copy.payload['value'], 2);
      expect(copy.version, 2);
      expect(copy.updatedAt, created.add(const Duration(days: 1)));
    });

    test('equality does not depend on payload order', () {
      final samePayload = DataRecord(
        id: record.id,
        collection: record.collection,
        payload: {'value': 1},
        version: record.version,
        createdAt: record.createdAt,
        updatedAt: record.updatedAt,
      );
      expect(samePayload, equals(record));
    });
  });

  group('RecordPatch', () {
    test('applies set and unset operations', () {
      final patch = RecordPatch(set: {'a': 1}, unset: ['b']);
      final source = {'b': 2, 'c': 3};
      final result = patch.apply(source);
      expect(result, containsPair('a', 1));
      expect(result, isNot(contains('b')));
      expect(result['c'], 3);
    });
  });

  group('Filters and options', () {
    test('RangeFilter serializes round-trip', () {
      final filter = RangeFilter(
        min: 1,
        max: 2,
        includeMin: false,
        includeMax: true,
      );
      expect(RangeFilter.fromJson(filter.toJson()), equals(filter));
    });

    test('SortOrder round-trips', () {
      final sort = SortOrder(field: 'field', descending: true);
      expect(SortOrder.fromJson(sort.toJson()), equals(sort));
    });

    test('QueryOptions validates bounds', () {
      expect(() => QueryOptions(limit: 0), throwsA(isA<AssertionError>()));
      expect(
        () => QueryOptions(limit: 1, offset: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  test(
    'RpcStreamIterator moves through a stream and cancels cleanly',
    () async {
      final controller = StreamController<int>();
      final iterator = controller.stream.iterator;
      controller.add(1);
      controller.close();

      expect(() => iterator.current, throwsStateError);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, 1);
      expect(await iterator.moveNext(), isFalse);
      await iterator.cancel();
    },
  );
}
