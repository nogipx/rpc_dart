// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every collection in LogCollectorMcpBuffer is bounded -- records by
// maxRecords, trace ids at 500, unique errors at 5 -- except _scopeStats,
// which was not. Scope names come from the connected devices, and applications
// routinely build them per request or per entity via LogScope.child(...), so
// cardinality is caller-controlled. Being cumulative, the stats also outlived
// the records they summarise: with maxRecords = 100 and 5000 rotating scopes
// the buffer held 100 records and 5000 scope entries -- a 50x overhang that
// grows for as long as the collector runs.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/src/protocol.dart';
import 'package:rpc_dart_log/src/mcp_buffer.dart';
import 'package:test/test.dart';

TaggedRecord _record(String scope) => TaggedRecord(
  deviceLabel: 'dev',
  record: LogEvent(
    level: RpcLogLevel.info,
    scope: scope,
    message: 'm',
    timestamp: DateTime.utc(2026),
  ),
);

/// Total scopes the buffer is tracking, read back from the rendered summary
/// (it shows the top 15 and reports the rest as "... +N more scopes").
int _trackedScopes(LogCollectorMcpBuffer buffer) {
  final lines = buffer.sources(const []).split('\n');
  final shown = lines
      .skipWhile((l) => !l.startsWith('Scopes:'))
      .skip(1)
      .takeWhile((l) => l.startsWith('  ') && !l.contains('more scopes'))
      .length;
  final overflow = lines.firstWhere(
    (l) => l.contains('more scopes'),
    orElse: () => '',
  );
  if (overflow.isEmpty) return shown;
  return shown +
      int.parse(RegExp(r'\+(\d+) more scopes').firstMatch(overflow)!.group(1)!);
}

void main() {
  test('scope stats stay bounded when scope names rotate', () {
    final buffer = LogCollectorMcpBuffer(maxRecords: 100);

    for (var i = 0; i < 5000; i++) {
      buffer.addRecord(_record('req-$i'));
    }

    expect(
      _trackedScopes(buffer),
      lessThanOrEqualTo(500),
      reason: 'the scope index grew to 5000 while records were capped at 100',
    );
  });

  test('a stable set of scopes is fully retained', () {
    final buffer = LogCollectorMcpBuffer(maxRecords: 100);

    // The ordinary case: few scopes, many records. Nothing may be evicted.
    for (var i = 0; i < 1000; i++) {
      buffer.addRecord(_record('scope-${i % 8}'));
    }

    expect(_trackedScopes(buffer), 8);
  });
}
