// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 428 left this file behind: it began as the probe that measured whether
// `isolate_transport_web.dart` can be imported on the VM (it cannot -- it opens
// with `dart:js_interop`), and the round could not delete it, because the loop
// runs without a shell that may remove files.
//
// Its content moved to two files that say what they are:
//   web_bridge_stays_vm_importable_test.dart     -- the boundary it pins
//   web_channel_survives_a_bad_payload_test.dart -- B-31's witness
//
// SAFE TO DELETE.

import 'package:test/test.dart';

void main() {
  test('superseded: see web_bridge_stays_vm_importable_test.dart', () {
    expect(true, isTrue);
  });
}
