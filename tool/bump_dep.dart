// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

/// Raises the floor of an in-repo dependency across every package that uses it.
///
/// Usage (from the repo root):
///   fvm dart run tool/bump_dep.dart <package> [version] [--dry-run]
///
///   fvm dart run tool/bump_dep.dart rpc_dart            # floor = current rpc_dart version
///   fvm dart run tool/bump_dep.dart rpc_dart_generator  # floor = its current version
///   fvm dart run tool/bump_dep.dart rpc_dart 4.3.0      # explicit version
///   fvm dart run tool/bump_dep.dart rpc_dart --dry-run  # preview, write nothing
///
/// Handles both constraint forms used in this repo and preserves the form:
///   rpc_dart:           '>=X <Y'  ->  '>=<target> <Y>'   (range; floor only)
///   rpc_dart_generator: ^X        ->  ^<target>          (caret)
/// Edits are line-level (formatting/comments preserved), never lower a floor,
/// skip the package's own pubspec, and warn on any other constraint shape.
/// Run `fvm dart pub get` at the repo root afterwards.
void main(List<String> args) {
  final dryRun = args.contains('--dry-run') || args.contains('-n');
  final positional = args.where((a) => !a.startsWith('-')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: bump_dep.dart <package> [version] [--dry-run]',
    );
    exit(64);
  }
  final package = positional.first;

  final root = _repoRoot();
  if (root == null) {
    stderr.writeln('Run this from the rpc_dart repo (no packages/ found).');
    exit(1);
  }

  final ownPubspec = _findPackagePubspec(root, package);
  final target = positional.length > 1
      ? positional[1]
      : (ownPubspec == null ? null : _readVersion(ownPubspec));
  if (target == null) {
    stderr.writeln(
      'Could not determine a version for "$package" (pass one explicitly).',
    );
    exit(1);
  }

  // A line that declares `<package>: <value>` (colon immediately after the name,
  // so `rpc_dart:` never matches `rpc_dart_generator:`).
  final depLine = RegExp('^(\\s*${RegExp.escape(package)}:\\s*)(\\S.*)\$');

  var changedFiles = 0;
  var matchedPackages = 0;

  for (final pubspec in _pubspecs(root)) {
    if (ownPubspec != null && pubspec.path == ownPubspec.path) continue;

    final lines = pubspec.readAsLinesSync();
    var fileChanged = false;
    var matched = false;
    for (var i = 0; i < lines.length; i++) {
      final m = depLine.firstMatch(lines[i]);
      if (m == null) continue;
      matched = true;
      final rewritten = _rewriteConstraint(m.group(2)!, target);
      if (rewritten == null) {
        // Unknown shape (or already >= target): only warn for shapes we can't
        // edit, not for no-op cases.
        if (!_isHandledShape(m.group(2)!)) {
          stderr.writeln(
            'WARN ${_rel(root, pubspec)}: $package constraint not in a '
            "supported form ('>=X <Y' or ^X), skipped: ${m.group(2)!.trim()}",
          );
        }
        continue;
      }
      lines[i] = '${m.group(1)}$rewritten';
      fileChanged = true;
      stdout.writeln(
        '${_rel(root, pubspec)}: $package ${m.group(2)!.trim()} -> $rewritten',
      );
    }
    if (matched) matchedPackages++;
    if (fileChanged) {
      changedFiles++;
      if (!dryRun) pubspec.writeAsStringSync('${lines.join('\n')}\n');
    }
  }

  stdout.writeln(
    '${dryRun ? '[dry-run] would update' : 'Updated'} $changedFiles of '
    '$matchedPackages package(s) using $package (floor >=$target).'
    '${dryRun ? '' : ' Now run: fvm dart pub get'}',
  );
}

/// Rewrites [value] to floor [target], preserving the constraint form. Returns
/// null when the shape is unhandled or the change would not raise the floor.
String? _rewriteConstraint(String value, String target) {
  final v = value.trim();

  // Quoted range: '>=FLOOR <UPPER'  (keep the upper bound).
  final range = RegExp(r"^('?)>=([0-9][0-9.]*)( +<[^'\s]*)('?)$").firstMatch(v);
  if (range != null) {
    if (_compare(target, range.group(2)!) <= 0) return null;
    return '${range.group(1)}>=$target${range.group(3)}${range.group(4)}';
  }

  // Caret: ^X
  final caret = RegExp(r'^\^([0-9][0-9.]*)$').firstMatch(v);
  if (caret != null) {
    if (_compare(target, caret.group(1)!) <= 0) return null;
    return '^$target';
  }

  return null;
}

bool _isHandledShape(String value) {
  final v = value.trim();
  return RegExp(r"^'?>=[0-9]").hasMatch(v) || RegExp(r'^\^[0-9]').hasMatch(v);
}

Directory? _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/packages').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Iterable<File> _pubspecs(Directory root) sync* {
  for (final entity
      in Directory('${root.path}/packages').listSync(recursive: true)) {
    if (entity is File &&
        entity.uri.pathSegments.last == 'pubspec.yaml' &&
        !entity.path.contains('.dart_tool')) {
      yield entity;
    }
  }
}

File? _findPackagePubspec(Directory root, String package) {
  for (final pubspec in _pubspecs(root)) {
    for (final line in pubspec.readAsLinesSync()) {
      if (RegExp('^name:\\s*${RegExp.escape(package)}\\s*\$').hasMatch(line)) {
        return pubspec;
      }
    }
  }
  return null;
}

String? _readVersion(File pubspec) {
  for (final line in pubspec.readAsLinesSync()) {
    final m = RegExp(r'^version:\s*(\S+)').firstMatch(line);
    if (m != null) return m.group(1);
  }
  return null;
}

String _rel(Directory root, File f) => f.path.replaceFirst('${root.path}/', '');

/// Compares dot-separated versions ignoring pre-release/build suffixes.
/// Negative if [a] < [b], 0 if equal, positive if [a] > [b].
int _compare(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp('[-+]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}
