/// Supported lifecycle states of an outbox entry.
enum OutboxStatus {
  /// Entry is ready to be claimed.
  pending,

  /// Entry is claimed by a worker and should not be processed by others.
  processing,

  /// Entry was successfully delivered.
  delivered,

  /// Entry failed permanently.
  failed,
}
