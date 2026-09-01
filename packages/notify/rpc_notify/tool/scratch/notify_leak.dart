import 'dart:async';
import 'package:rpc_notify/rpc_notify.dart';

Future<void> main() async {
  var created = 0, cancelled = 0;

  await runZoned(() async {
    final repo = InMemoryNotifyRepository();
    // A pub/sub server sees client-supplied topic names.
    for (var i = 0; i < 20; i++) {
      final topic = 'topic-$i';
      final sub = repo.subscribe('client', topic).listen((_) {});
      repo.unsubscribe('client', topic);
      await sub.cancel();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    print('activeTopics reported: ${repo.activeTopics().length}');
  }, zoneSpecification: ZoneSpecification(
    createPeriodicTimer: (self, parent, zone, period, f) {
      created++;
      final t = parent.createPeriodicTimer(zone, period, f);
      return _CountingTimer(t, () => cancelled++);
    },
  ));

  print('periodic timers created=$created cancelled=$cancelled '
      'STILL RUNNING=${created - cancelled}');
}

class _CountingTimer implements Timer {
  _CountingTimer(this._inner, this._onCancel);
  final Timer _inner;
  final void Function() _onCancel;
  var _done = false;
  @override
  void cancel() { if (!_done) { _done = true; _onCancel(); } _inner.cancel(); }
  @override
  bool get isActive => _inner.isActive;
  @override
  int get tick => _inner.tick;
}
