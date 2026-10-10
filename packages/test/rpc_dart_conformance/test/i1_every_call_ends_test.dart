// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-1 -- every call ends.
//
// A call of any shape ends, with a result or a status, within its deadline
// + 1 s, on every transport, whatever the peer does: silent, slow, half-open,
// closes mid-frame.
//
// Rows: shape x peer behaviour, each on its own connection; then two rows
// that put many calls on ONE connection (L-08), one with a working peer and
// one whose peer dies under them.

@TestOn('vm')
library;

import 'package:test/test.dart';

import 'support/matrix.dart';

const _deadline = Duration(milliseconds: 300);
const _bound = Duration(milliseconds: 1300); // deadline + 1 s

const _knownFailing = <String, String>{};

void main() {
  for (final behaviour in PeerBehaviour.values) {
    group('I-1 every call ends, peer ${behaviour.name}:', () {
      for (final member in members) {
        for (final shape in CallShape.values) {
          cell(
            member,
            '${shape.name} peer ${behaviour.name}',
            behaviour: behaviour,
            knownFailing: _knownFailing,
            () async {
              final rig = await member.serve(behaviour: behaviour);
              addTearDown(rig.close);
              final caller = await rig.caller();

              final call = Call.start(
                caller,
                shape,
                Blob.request(
                  id: nextCallId(),
                  responseSize: cutResponseSize,
                  count: 2,
                ),
                deadline: _deadline,
              );
              final outcome = await endsWithin(
                call,
                _bound,
                'peer ${behaviour.name}',
              );

              if (behaviour == PeerBehaviour.normal) {
                // GUARD: the working peer answers, so an ending above is not
                // the harness failing every call.
                expect(outcome.ok, isTrue, reason: '$outcome');
                expect(
                  outcome.responses.map((r) => r.length),
                  everyElement(cutResponseSize),
                );
              }
            },
          );
        }
      }
    });
  }

  group('I-1 many calls on one connection:', () {
    for (final member in members) {
      cell(member, '40 calls, every shape, working peer', () async {
        final rig = await member.serve();
        addTearDown(rig.close);
        final caller = await rig.caller();

        final calls = [
          for (var i = 0; i < 10; i++)
            for (final shape in CallShape.values)
              Call.start(
                caller,
                shape,
                Blob.request(id: nextCallId(), responseSize: 1024),
                deadline: _deadline * 4,
              ),
        ];
        for (final call in calls) {
          final outcome = await endsWithin(call, _deadline * 4 + _bound, '');
          expect(outcome.ok, isTrue, reason: '${call.shape.name}: $outcome');
        }
      });

      cell(
        member,
        '20 hanging calls, the peer dies under them',
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve();
          addTearDown(rig.close);
          final caller = await rig.caller();
          const deadline = Duration(seconds: 1);

          final calls = [
            for (var i = 0; i < 5; i++)
              for (final shape in CallShape.values)
                Call.start(
                  caller,
                  shape,
                  Blob.request(id: nextCallId(), mode: Mode.hang),
                  deadline: deadline,
                ),
          ];
          // Every handler is running before the peer goes.
          await rig.probe.waitForCount('enter', calls.length);
          await rig.killPeer();

          for (final call in calls) {
            await endsWithin(call, deadline + const Duration(seconds: 1), '');
          }
        },
      );
    }
  });
}
