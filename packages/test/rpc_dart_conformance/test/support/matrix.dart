// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// How a row declares its cells, so every cell is named and skipped the same
// way in every file.

import 'package:test/test.dart';

import 'members.dart';
import 'peer.dart';

export 'calls.dart';
export 'contract.dart';
export 'members.dart';
export 'peer.dart';

/// Declares the cell of [member] in a row. The name is
/// `<member> | <detail>`, so a member shows up in every row it is listed in.
///
/// The skip, first match wins: the member cannot run here; the member cannot
/// produce [behaviour]; [skip], which a row uses for a condition of its own;
/// the row's [knownFailing] entry for `<member> | <detail>`.
void cell(
  Member member,
  String detail,
  Future<void> Function() body, {
  PeerBehaviour? behaviour,
  String? skip,
  Map<String, String> knownFailing = const {},
  Duration timeout = const Duration(seconds: 15),
}) {
  final name = '${member.name} | $detail';
  final known = knownFailing[name];
  test(
    name,
    body,
    skip:
        member.skip ??
        (behaviour == null ? null : member.cannotProduce(behaviour)) ??
        skip ??
        (known == null ? null : 'KNOWN FAILING: $known'),
    timeout: Timeout(timeout),
  );
}
