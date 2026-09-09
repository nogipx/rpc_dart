// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

/// Waits for a byte counter to settle, and returns as soon as the verdict
/// cannot change.
///
/// The upload-bound tests all had the same shape: push into a handler that
/// consumes nothing, sleep a flat 8 s, then assert the wire count stayed under
/// a ceiling. The sleep was chosen so that steady growth could not be mistaken
/// for a ceiling — a real requirement — but it was paid on every run, by every
/// case, including the ones that had plainly settled after two seconds. Seven
/// tests across two files, ~8 s each.
///
/// Two outcomes are decidable early, and neither weakens the assertion:
///
///  * **breach** — the count is already past [ceiling], so the test will fail
///    whatever happens next. Only the failure is being delayed.
///  * **plateau** — the count has not moved for [plateauFor], so the bound has
///    engaged. Waiting longer cannot change a number that is not changing.
///
/// Anything still climbing below the ceiling gets the whole [budget], which is
/// the case the flat sleep existed for.
///
/// [settleFloor] is load-bearing and was added after a first cut got it wrong:
/// with a 0.9 s plateau and no floor, these tests exited mid-ramp during a lull
/// in the producer's pacing and measured **1.8-2.4 MiB where the bounded steady
/// state is 4.1 MiB**. They still passed, because the ceiling is 8 MiB — a
/// faster test that silently measures less of the curve. Nothing counts as
/// settled before the floor.
Future<void> settleBytes(
  int Function() sample, {
  required int ceiling,
  Duration budget = const Duration(seconds: 8),
  Duration settleFloor = const Duration(seconds: 3),
  Duration plateauFor = const Duration(milliseconds: 1500),
  Duration interval = const Duration(milliseconds: 150),
}) async {
  final start = DateTime.now();
  final deadline = start.add(budget);
  final floor = start.add(settleFloor);
  final plateauSamples = plateauFor.inMilliseconds ~/ interval.inMilliseconds;

  var last = -1;
  var still = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(interval);
    final now = sample();
    if (now >= ceiling) return; // breach: the verdict is settled
    if (now == last) {
      still++;
      if (still >= plateauSamples && DateTime.now().isAfter(floor)) {
        return; // plateau
      }
    } else {
      still = 0;
      last = now;
    }
  }
}
