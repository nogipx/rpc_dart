// A probe skeleton: one number, a control flag, the same bench in both modes.
//
// Run:  dart run tool/probe_<name>.dart            — the case under test
//       dart run tool/probe_<name>.dart --control  — the control: the same
//                                                    bench with the suspected
//                                                    mechanism removed
// Prints one line, `metric=<number>` — that is what the round record quotes.
// The probe lives where config.md says ("Probes") and stays out of git.

import 'dart:io';

Future<void> main(List<String> args) async {
  final control = args.contains('--control');
  final scales = [1, 4, 16]; // three scales: read the per-unit value as a curve

  for (final scale in scales) {
    final before = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();

    // 1. Stand the bench up. The two sides get SEPARATE configuration objects.
    //    No policy is shared between the attacker and the victim.
    // 2. Drive `scale` units of load. Under `control`, the same volume and the
    //    same path, but without the suspected mechanism (or with the fix off).
    // 3. Wait for the plateau: measure the delta per interval, not one number.

    await Future<void>.delayed(Duration.zero); // replace with the load

    sw.stop();
    final after = ProcessInfo.currentRss;
    final perUnit = (after - before) / scale;
    stdout.writeln('scale=$scale control=$control '
        'rss_delta=${after - before} per_unit=${perUnit.toStringAsFixed(1)} '
        'ms=${sw.elapsedMilliseconds}');
  }

  // The number that goes into the round record is single and named.
  stdout.writeln('metric=<fill in>');
}
