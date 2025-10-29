import '../lib/src/change_journal.dart';
import '../lib/src/models.dart';

Future<void> main(List<String> args) async {
  final label = args.isNotEmpty ? args.first : 'run';
  const totalEvents = 50000;
  final journal = InMemoryDataChangeJournal();
  final now = DateTime.utc(2024, 1, 1);
  final samplePositions = <int>{0, 1, 10, 100, 1000, 10000, totalEvents - 2};
  final sampleCursors = <int, String>{};
  String lastCursor = '';

  for (var i = 0; i < totalEvents; i++) {
    final event = await journal.recordChange(
      type: DataChangeType.updated,
      collection: 'tasks',
      id: 'task-$i',
      version: i,
      occurredAt: now.add(Duration(seconds: i)),
      record: DataRecord(
        id: 'task-$i',
        collection: 'tasks',
        payload: const {'value': 'x'},
        version: i,
        createdAt: now,
        updatedAt: now,
      ),
    );
    lastCursor = event.cursor;
    if (samplePositions.contains(i)) {
      sampleCursors[i] = event.cursor;
    }
  }

  final queries = <(String?, String)>[
    (null, 'full backlog'),
    ...sampleCursors.entries
        .map((entry) => (entry.value, 'after #${entry.key}')),
    (lastCursor, 'after last'),
  ];

  for (final query in queries) {
    final sw = Stopwatch()..start();
    final events =
        await journal.replayCollection('tasks', afterCursor: query.$1);
    sw.stop();
    print(
      '[$label] Replay ${query.$2.padRight(14)} -> ${events.length.toString().padLeft(6)} events in ${sw.elapsedMilliseconds}ms',
    );
  }
}
