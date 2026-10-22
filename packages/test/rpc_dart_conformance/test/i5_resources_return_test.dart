// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-5 -- resources return.
//
// After every call has ended, active streams, handler slots, flow-control
// credit and timers are back at their baseline.
//
// Observed on both sides through the public gauges: the endpoints' integer
// metrics (`activeResponders`, `openStreams`, `pendingRequests`, ...), every
// integer the transport's health() reports, and a channel transport's
// `flowControl` map in that report. The handler's timer is held through its call scope,
// and its release is an event the handler reports (L-11), as is the scope's
// disposal.
//
// Each cell first sees the RISE (the call holds a handler slot and a pending
// request) and only then waits for the return to baseline (tests item 2).
// `transport.finishedStreams` is excluded: the core documents it as bounded,
// not as returning to zero.
//
// A last row closes the caller after each peer behaviour: a close that never
// returns holds whatever the transport owns.

@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/matrix.dart';

enum _Ending { completes, deadline, callerCancels, handlerFails }

const _notAGauge = {'transport.finishedStreams'};

/// The same as I-6's http cells: the release follows the cancel, which on
/// macOS reaches the server about 4.2 s late through the harness; on Linux
/// these cells pass (B-284).
const _httpLateOnMacOS =
    'macOS only: the handler reports "disposed" after the 2000 ms bound: '
    'the cancel reaches the http server about 4.2 s late through the harness';

final _knownFailing = <String, String>{
  if (Platform.isMacOS) ...{
    'http | unary callerCancels': _httpLateOnMacOS,
    'http | clientStream callerCancels': _httpLateOnMacOS,
    'http | serverStream callerCancels': _httpLateOnMacOS,
    'http | bidi callerCancels': _httpLateOnMacOS,
    'http | 40 calls, every shape and ending': _httpLateOnMacOS,
  },
};

Future<Map<String, int>> _client(ConformanceCaller caller) async {
  final out = <String, int>{};
  for (final e in caller.endpoint.collectEndpointMetrics().toJson().entries) {
    if (e.value is int) out[e.key] = e.value! as int;
  }
  out.addAll(await transportGauges(caller.endpoint.transport));
  return out;
}

/// The keys of [now] that differ from [baseline] (a missing key is 0).
Map<String, String> _drift(Map<String, int> baseline, Map<String, int> now) => {
  for (final k in {...baseline.keys, ...now.keys})
    if (!_notAGauge.contains(k) && (baseline[k] ?? 0) != (now[k] ?? 0))
      k: '${baseline[k] ?? 0} -> ${now[k] ?? 0}',
};

Future<void> _backAtBaseline(
  Rig rig,
  ConformanceCaller caller,
  Map<String, int> serverBase,
  Map<String, int> clientBase,
) async {
  await pollUntil(
    () async => _drift(serverBase, await rig.serverMetrics()),
    (d) => d.isEmpty,
    what: 'server gauges not back at baseline',
  );
  await pollUntil(
    () async => _drift(clientBase, await _client(caller)),
    (d) => d.isEmpty,
    what: 'client gauges not back at baseline',
  );
}

void main() {
  for (final ending in _Ending.values) {
    group('I-5 resources return after a call that ${ending.name}:', () {
      for (final member in members) {
        for (final shape in CallShape.values) {
          cell(
            member,
            '${shape.name} ${ending.name}',
            knownFailing: _knownFailing,
            () async {
              final rig = await member.serve();
              addTearDown(rig.close);
              final caller = await rig.caller();
              // A first call opens whatever the connection opens lazily, so
              // the baseline is a connection that has carried a call.
              await Call.start(
                caller,
                shape,
                Blob.request(id: nextCallId()),
              ).outcome;
              final serverBase = await rig.serverMetrics();
              final clientBase = await _client(caller);
              final id = nextCallId();

              final call = Call.start(
                caller,
                shape,
                switch (ending) {
                  _Ending.completes => Blob.request(
                    id: id,
                    mode: Mode.hold,
                    delayMs: 300,
                  ),
                  _Ending.deadline || _Ending.callerCancels => Blob.request(
                    id: id,
                    mode: Mode.hang,
                  ),
                  _Ending.handlerFails => Blob.request(
                    id: id,
                    mode: Mode.fail,
                    delayMs: 300,
                  ),
                },
                deadline: ending == _Ending.deadline
                    ? const Duration(milliseconds: 400)
                    : null,
              );

              // The rise.
              await rig.probe.waitFor('enter', id);
              final during = await rig.serverMetrics();
              expect(during['activeResponders'], greaterThanOrEqualTo(1));
              expect(
                (await _client(caller))['pendingRequests'],
                greaterThanOrEqualTo(1),
              );

              if (ending == _Ending.callerCancels) await call.cancel();
              final outcome = await endsWithin(
                call,
                const Duration(seconds: 2),
                ending.name,
              );
              expect(
                outcome.ok,
                ending == _Ending.completes,
                reason: '$outcome',
              );

              await rig.probe.waitFor('disposed', id);
              await rig.probe.waitFor('timerCancelled', id);
              await _backAtBaseline(rig, caller, serverBase, clientBase);
            },
          );
        }
      }
    });
  }

  group('I-5 resources return after many calls on one connection:', () {
    for (final member in members) {
      cell(
        member,
        '40 calls, every shape and ending',
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve();
          addTearDown(rig.close);
          final caller = await rig.caller();
          await Call.start(
            caller,
            CallShape.unary,
            Blob.request(id: nextCallId()),
          ).outcome;
          final serverBase = await rig.serverMetrics();
          final clientBase = await _client(caller);

          final calls = <(int, _Ending, Call)>[];
          for (var i = 0; i < 10; i++) {
            final shape = CallShape.values[i % CallShape.values.length];
            for (final ending in _Ending.values) {
              final id = nextCallId();
              final mode = switch (ending) {
                _Ending.completes => Mode.hold,
                _Ending.handlerFails => Mode.fail,
                _ => Mode.hang,
              };
              calls.add((
                id,
                ending,
                Call.start(
                  caller,
                  shape,
                  Blob.request(id: id, mode: mode, delayMs: 100),
                  deadline: ending == _Ending.deadline
                      ? const Duration(milliseconds: 400)
                      : null,
                ),
              ));
            }
          }
          await rig.probe.waitForCount('enter', calls.length);
          for (final (_, ending, call) in calls) {
            if (ending == _Ending.callerCancels) await call.cancel();
          }
          for (final (id, ending, call) in calls) {
            await endsWithin(call, const Duration(seconds: 2), ending.name);
            await rig.probe.waitFor('timerCancelled', id);
          }
          await _backAtBaseline(rig, caller, serverBase, clientBase);
        },
      );
    }
  });

  group('I-5 the caller closes after its peer was:', () {
    for (final behaviour in PeerBehaviour.values) {
      for (final member in members) {
        cell(
          member,
          'close after peer ${behaviour.name}',
          behaviour: behaviour,
          knownFailing: _knownFailing,
          () async {
            final rig = await member.serve(behaviour: behaviour);
            addTearDown(rig.close);
            final caller = await rig.caller();
            await Call.start(
              caller,
              CallShape.unary,
              Blob.request(id: nextCallId(), responseSize: cutResponseSize),
              deadline: const Duration(milliseconds: 300),
            ).outcome;

            // An http2 close spends up to its 2 s graceful budget by design;
            // the endpoint's own bound on a transport close is 5 s.
            final clock = Stopwatch()..start();
            await caller.endpoint.transport.close().timeout(
              const Duration(seconds: 3),
              onTimeout: () => fail(
                'the ${member.name} caller transport did not close within 3 s',
              ),
            );
            expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
          },
        );
      }
    }
  });
}
