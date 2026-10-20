// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

/// Checks a package's public API against a committed snapshot.
///
/// Usage (from the repo root):
///   fvm dart run tool/api_snapshot.dart                 # check rpc_dart
///   fvm dart run tool/api_snapshot.dart --update        # rewrite the snapshot
///   fvm dart run tool/api_snapshot.dart <package dir> [--update]
///
/// The snapshot is `docs/api/<package>.txt`: one line per public declaration,
/// sorted, with the libraries that export it. A check that finds a difference
/// prints the added and removed lines and exits 1. A removed line, or one that
/// changed, breaks someone; an added one does not. Review it, then run with
/// --update and commit the new snapshot with the change.
///
/// The API comes from `dart_apitool extract`. Its `diff` command cannot be used
/// here: it fails on a named constructor and an instance method of the same
/// name (`RpcContext.withTimeout` and `context.withTimeout`). Install it once:
///   fvm dart pub global activate dart_apitool 0.23.2
Future<void> main(List<String> args) async {
  final update = args.contains('--update');
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final packageDir = positional.isEmpty
      ? 'packages/core/rpc_dart'
      : positional.first;

  final name = _packageName(packageDir);
  if (name == null) {
    stderr.writeln('No pubspec.yaml with a name in $packageDir.');
    exit(64);
  }

  final current = await _extract(packageDir);
  final snapshot = File('docs/api/$name.txt');

  if (update) {
    snapshot.parent.createSync(recursive: true);
    snapshot.writeAsStringSync('${current.join('\n')}\n');
    stdout.writeln('Wrote ${snapshot.path}: ${current.length} lines.');
    return;
  }

  if (!snapshot.existsSync()) {
    stderr.writeln('No snapshot at ${snapshot.path}; run with --update.');
    exit(1);
  }
  final committed = snapshot
      .readAsLinesSync()
      .where((line) => line.isNotEmpty)
      .toList();

  final removed = committed.toSet().difference(current.toSet());
  final added = current.toSet().difference(committed.toSet());
  if (removed.isEmpty && added.isEmpty) {
    stdout.writeln('$name: public API matches ${snapshot.path}.');
    return;
  }

  stdout.writeln('$name: public API differs from ${snapshot.path}.');
  if (removed.isNotEmpty) {
    stdout.writeln(
      '\nRemoved or changed (breaks callers or implementers; a new optional '
      'parameter breaks only an override):',
    );
    for (final line in removed.toList()..sort()) {
      stdout.writeln('- $line');
    }
  }
  if (added.isNotEmpty) {
    stdout.writeln('\nAdded:');
    for (final line in added.toList()..sort()) {
      stdout.writeln('+ $line');
    }
  }
  stdout.writeln(
    '\nIf intended, run: fvm dart run tool/api_snapshot.dart $packageDir '
    '--update',
  );
  exit(1);
}

String? _packageName(String dir) {
  final pubspec = File('$dir/pubspec.yaml');
  if (!pubspec.existsSync()) return null;
  for (final line in pubspec.readAsLinesSync()) {
    final match = RegExp(r'^name:\s*(\S+)').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// Runs `dart_apitool extract` on [packageDir] and returns the sorted lines.
Future<List<String>> _extract(String packageDir) async {
  final out = Directory.systemTemp.createTempSync('api_snapshot');
  try {
    final json = '${out.path}/api.json';
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'global',
      'run',
      'dart_apitool:main',
      'extract',
      '--input',
      packageDir,
      '--output',
      json,
    ]);
    if (result.exitCode != 0 || !File(json).existsSync()) {
      stderr
        ..writeln('dart_apitool extract failed (exit ${result.exitCode}).')
        ..writeln(result.stdout)
        ..writeln(result.stderr)
        ..writeln(
          'Install it with: fvm dart pub global activate dart_apitool 0.23.2',
        );
      exit(1);
    }
    final decoded =
        jsonDecode(File(json).readAsStringSync()) as Map<String, dynamic>;
    if (decoded['version'] != 3) {
      stderr.writeln(
        'dart_apitool wrote format version ${decoded['version']}; this tool '
        'reads version 3.',
      );
      exit(1);
    }
    return _lines(
      decoded['packageApi'] as Map<String, dynamic>,
      _barrelExports(packageDir),
    );
  } finally {
    out.deleteSync(recursive: true);
  }
}

/// Which public libraries export each name, from the `show` lists of the
/// libraries directly under `lib/`. Null when one of them exports a `src/`
/// file without a `show`, and so everything in it.
///
/// dart_apitool ignores `show`: it reports every declaration of an exported
/// file, hidden names included, and labels each with every library.
Map<String, Set<String>>? _barrelExports(String packageDir) {
  final export = RegExp(
    r"export\s+'([^']+)'((?:\s+show\s+)([^;]*))?\s*;",
    multiLine: true,
  );
  final barrels = Directory('$packageDir/lib')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.uri.pathSegments.last)
      .toSet();

  final direct = <String, Set<String>>{};
  final reexports = <String, Set<String>>{};
  for (final barrel in barrels) {
    final source = File(
      '$packageDir/lib/$barrel',
    ).readAsStringSync().replaceAll(RegExp(r'//[^\n]*'), '');
    direct[barrel] = {};
    reexports[barrel] = {};
    for (final match in export.allMatches(source)) {
      final target = match.group(1)!;
      if (target.startsWith('dart:')) continue;
      final shown = match.group(3);
      if (shown == null) {
        if (!barrels.contains(target)) return null;
        reexports[barrel]!.add(target);
        continue;
      }
      direct[barrel]!.addAll(
        shown.split(',').map((n) => n.trim()).where((n) => n.isNotEmpty),
      );
    }
  }

  Set<String> namesOf(String barrel, Set<String> seen) {
    if (!seen.add(barrel)) return {};
    return {
      ...direct[barrel]!,
      for (final other in reexports[barrel]!) ...namesOf(other, seen),
    };
  }

  final byName = <String, Set<String>>{};
  for (final barrel in barrels) {
    for (final name in namesOf(barrel, {})) {
      (byName[name] ??= {}).add(barrel);
    }
  }
  return byName;
}

List<String> _lines(
  Map<String, dynamic> api,
  Map<String, Set<String>>? exports,
) {
  final lines = <String>[];
  bool shown(Map<String, dynamic> d) =>
      exports == null || exports.containsKey(d['name']);
  String exportedBy(Map<String, dynamic> d) => exports == null
      ? _exportedBy(d)
      : '(${(exports[d['name']]!.toList()..sort()).join(', ')})';

  for (final type in _list(api['interfaceDeclarations']).where(shown)) {
    final name = '${type['name']}${_typeParams(type)}';
    final supers = (_list(
      type['superTypeNames'],
    ).cast<String>().toList()..sort()).join(', ');
    final flags = [
      if (type['isSealed'] == true) 'sealed',
      if (type['isRequired'] == true) 'required',
      ..._deprecation(type),
    ];
    lines.add(
      'type $name${_flags(flags)} : $supers ${exportedBy(type)}'.trimRight(),
    );
    for (final member in _list(type['executableDeclarations'])) {
      lines.add('${type['name']} ${_executable(member)}');
    }
    for (final field in _list(type['fieldDeclarations'])) {
      lines.add('${type['name']} ${_field(field)}');
    }
  }
  for (final member in _list(api['executableDeclarations']).where(shown)) {
    lines.add('top ${_executable(member)} ${exportedBy(member)}'.trimRight());
  }
  for (final field in _list(api['fieldDeclarations']).where(shown)) {
    lines.add('top ${_field(field)} ${exportedBy(field)}'.trimRight());
  }
  for (final alias in _list(api['typeAliasDeclarations']).where(shown)) {
    lines.add(
      'typedef ${alias['name']} = ${alias['aliasedTypeName']}'
              '${_flags(_deprecation(alias))} ${exportedBy(alias)}'
          .trimRight(),
    );
  }

  if (exports != null) {
    final found = {
      for (final key in [
        'interfaceDeclarations',
        'executableDeclarations',
        'fieldDeclarations',
        'typeAliasDeclarations',
      ])
        for (final d in _list(api[key])) d['name'] as String,
    };
    final missing = exports.keys.toSet().difference(found).toList()..sort();
    if (missing.isNotEmpty) {
      stderr.writeln(
        'Shown by a library but absent from the extracted API, so not '
        'covered by the snapshot: ${missing.join(', ')}',
      );
    }
  }

  return lines.toSet().toList()..sort();
}

List<Map<String, dynamic>> _list(Object? value) =>
    (value as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

String _typeParams(Map<String, dynamic> declaration) {
  final names = (declaration['typeParameterNames'] as List<dynamic>? ?? [])
      .cast<String>();
  return names.isEmpty ? '' : '<${names.join(', ')}>';
}

List<String> _deprecation(Map<String, dynamic> declaration) => [
  if (declaration['isDeprecated'] == true) 'deprecated',
  if (declaration['isExperimental'] == true) 'experimental',
];

String _flags(List<String> flags) =>
    flags.isEmpty ? '' : ' [${flags.join(', ')}]';

/// The public libraries that export a top-level declaration. Moving a type
/// from one library to another breaks the imports that found it there.
String _exportedBy(Map<String, dynamic> declaration) {
  final entryPoints =
      (declaration['entryPoints'] as List<dynamic>? ?? const [])
          .cast<String>()
          .toList()
        ..sort();
  return entryPoints.isEmpty ? '' : '(${entryPoints.join(', ')})';
}

String _executable(Map<String, dynamic> member) {
  final params = _list(member['parameters']);
  final positional = [
    for (final p in params)
      if (p['isNamed'] != true && p['isRequired'] == true)
        '${p['typeName']} ${p['name']}',
  ];
  final optional = [
    for (final p in params)
      if (p['isNamed'] != true && p['isRequired'] != true)
        '${p['typeName']} ${p['name']}',
  ];
  final named = [
    for (final p in params)
      if (p['isNamed'] == true)
        '${p['isRequired'] == true ? 'required ' : ''}'
            '${p['typeName']} ${p['name']}',
  ];
  final signature = [
    ...positional,
    if (optional.isNotEmpty) '[${optional.join(', ')}]',
    if (named.isNotEmpty) '{${named.join(', ')}}',
  ].join(', ');

  final isConstructor = member['type'] == 'constructor';
  final kind = isConstructor
      ? 'new'
      : '${member['isStatic'] == true ? 'static ' : ''}method';
  final returns = isConstructor ? '' : ' -> ${member['returnTypeName']}';
  return '$kind ${member['name']}${_typeParams(member)}($signature)$returns'
      '${_flags(_deprecation(member))}';
}

String _field(Map<String, dynamic> field) {
  final access = [
    if (field['isReadable'] == true) 'get',
    if (field['isWriteable'] == true) 'set',
  ].join('/');
  final kind = field['isStatic'] == true ? 'static field' : 'field';
  return '$kind ${field['name']}: ${field['typeName']} ($access)'
      '${_flags(_deprecation(field))}';
}
