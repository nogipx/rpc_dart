import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:rpc_dart_outbox/rpc_dart_outbox.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late InMemoryDataRepository data;
  late OutboxRepository outbox;

  setUp(() {
    now = DateTime.utc(2024, 1, 1, 12);
    data = InMemoryDataRepository(clock: () => now);
    outbox = OutboxRepository(repository: data, clock: () => now);
  });

  test('enqueue and claim move entry to processing and increment attempts',
      () async {
    final created = await outbox.enqueue(
      payload: {'type': 'email'},
      topic: 'emails',
    );

    final claimed = await outbox.claim(limit: 1, topic: 'emails');
    expect(claimed, hasLength(1));
    expect(claimed.first.id, created.id);
    expect(claimed.first.status, OutboxStatus.processing);
    expect(claimed.first.attempts, 1);
  });

  test('acknowledge transitions entry to delivered', () async {
    await outbox.enqueue(payload: {'type': 'email'}, topic: 'emails');
    final claimed = await outbox.claim(limit: 1, topic: 'emails');

    final acked = await outbox.acknowledge(claimed.first.id);
    expect(acked?.status, OutboxStatus.delivered);
  });

  test('retryLater delays the next claim until the delay passes', () async {
    await outbox.enqueue(payload: {'type': 'email'}, topic: 'emails');
    final claimed = await outbox.claim(limit: 1, topic: 'emails');

    await outbox.retryLater(claimed.first.id, delay: const Duration(minutes: 5));

    final immediate = await outbox.claim(limit: 1);
    expect(immediate, isEmpty);

    now = now.add(const Duration(minutes: 6));
    final retried = await outbox.claim(limit: 1);
    expect(retried, hasLength(1));
    expect(retried.first.attempts, 2);
    expect(retried.first.status, OutboxStatus.processing);
  });

  test('dedupKey avoids inserting duplicates', () async {
    final first = await outbox.enqueue(
      payload: {'type': 'email', 'userId': '1'},
      topic: 'emails',
      dedupKey: 'email-1',
    );
    final second = await outbox.enqueue(
      payload: {'type': 'email', 'userId': '1'},
      topic: 'emails',
      dedupKey: 'email-1',
    );

    expect(second.id, first.id);
    expect(second.payload, first.payload);
  });

  test('claim can filter by topic', () async {
    await outbox.enqueue(payload: {'type': 'email'}, topic: 'emails');
    await outbox.enqueue(payload: {'type': 'sms'}, topic: 'notifications');

    final emailBatch = await outbox.claim(limit: 5, topic: 'emails');
    expect(emailBatch, hasLength(1));
    expect(emailBatch.first.topic, 'emails');

    // notifications still pending because topic mismatch in previous claim
    final notifBatch = await outbox.claim(limit: 5, topic: 'notifications');
    expect(notifBatch, hasLength(1));
    expect(notifBatch.first.topic, 'notifications');
  });

  test('claim can iterate multiple topics until limit reached', () async {
    await outbox.enqueue(payload: {'type': 'email1'}, topic: 'emails');
    await outbox.enqueue(payload: {'type': 'email2'}, topic: 'emails');
    await outbox.enqueue(payload: {'type': 'sms1'}, topic: 'notifications');

    final batch = await outbox.claim(
      limit: 2,
      topics: const ['notifications', 'emails'],
    );

    expect(batch, hasLength(2));
    expect(batch.map((e) => e.topic), containsAll(['notifications', 'emails']));
  });
}
