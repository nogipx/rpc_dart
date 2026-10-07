// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

/// Checks the Agent Skills shipped in `packages/*/*/skills/`.
///
/// Usage (from the repo root):
///   fvm dart run tool/check_skills.dart
///
/// A skill is copied into the user's project and read by an agent that trusts
/// it, so a wrong example there is worse than one in prose docs. Per skill:
///
/// - `SKILL.md` opens with `---` frontmatter whose `name` equals the directory
///   name and starts with `<package>-` (the skills CLI silently skips any other
///   name), and whose `description` is non-empty.
/// - `SKILL.md` stays under 500 lines.
/// - Every relative markdown link in the skill points at an existing file.
/// - The ```dart blocks of each markdown file, joined in order with their
///   imports hoisted, form one library that passes `dart analyze
///   --fatal-infos` under the package's own analysis options. So a block is
///   always top-level code: statements go inside a function.
///
/// The joined sources are written to `<package>/.dart_tool/skill_snippets/`
/// (inside the package, so `package:` imports resolve) and removed afterwards.
/// Exits 1 on any violation, 0 when every skill is clean.
Future<void> main() async {
  final root = Directory.current;
  final packagesDir = Directory('${root.path}/packages');
  if (!packagesDir.existsSync()) {
    stderr.writeln('Run this from the rpc_dart repo root.');
    exit(1);
  }

  final problems = <String>[];
  var skillCount = 0;

  final packageDirs =
      packagesDir
          .listSync()
          .whereType<Directory>()
          .expand((group) => group.listSync().whereType<Directory>())
          .where((p) => Directory('${p.path}/skills').existsSync())
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final packageDir in packageDirs) {
    final packageName = _packageName(packageDir);
    final skillDirs =
        Directory(
            '${packageDir.path}/skills',
          ).listSync().whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final snippetDir = Directory(
      '${packageDir.path}/.dart_tool/skill_snippets',
    );
    if (snippetDir.existsSync()) snippetDir.deleteSync(recursive: true);
    snippetDir.createSync(recursive: true);
    final snippetFiles = <String, String>{};

    for (final skillDir in skillDirs) {
      skillCount++;
      final skillName = _basename(skillDir.path);
      final rel = _relative(root, skillDir.path);
      problems.addAll(_checkSkillMd(skillDir, skillName, packageName, rel));

      final mdFiles =
          skillDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.md'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final md in mdFiles) {
        final text = md.readAsStringSync();
        problems.addAll(_checkLinks(root, md, text));
        final library = _joinDartBlocks(text);
        if (library == null) continue;
        final mdRel = _relative(skillDir, md.path);
        final name = '${skillName}__$mdRel'
            .replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')
            .toLowerCase();
        final out = File('${snippetDir.path}/$name.dart')
          ..writeAsStringSync(library);
        snippetFiles[out.path] = _relative(root, md.path);
      }
    }

    if (snippetFiles.isNotEmpty) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'analyze',
        '--fatal-infos',
        ...snippetFiles.keys,
      ], workingDirectory: packageDir.path);
      if (result.exitCode != 0) {
        final output = '${result.stdout}${result.stderr}';
        for (final line in output.split('\n')) {
          if (!RegExp(r'^\s*(error|warning|info) - ').hasMatch(line)) continue;
          var message = line.trim();
          for (final entry in snippetFiles.entries) {
            final generated = _relative(packageDir, entry.key);
            message = message.replaceAll(generated, '${entry.value} (joined)');
          }
          problems.add(message);
        }
        if (!problems.any((p) => p.contains('(joined)'))) {
          problems.add('dart analyze failed in $packageName:\n$output');
        }
      }
    }
    snippetDir.deleteSync(recursive: true);
  }

  if (problems.isEmpty) {
    stdout.writeln('skills: $skillCount checked, clean.');
    return;
  }
  stderr
    ..writeln('skills: ${problems.length} problem(s) in $skillCount skill(s):')
    ..writeAll(problems.map((p) => '  $p'), '\n')
    ..writeln();
  exit(1);
}

List<String> _checkSkillMd(
  Directory skillDir,
  String skillName,
  String packageName,
  String rel,
) {
  final file = File('${skillDir.path}/SKILL.md');
  if (!file.existsSync()) return ['$rel: no SKILL.md'];
  final problems = <String>[];
  final lines = file.readAsLinesSync();
  if (lines.length >= 500) {
    problems.add('$rel/SKILL.md: ${lines.length} lines, keep it under 500');
  }
  if (lines.isEmpty || lines.first != '---') {
    return [
      ...problems,
      '$rel/SKILL.md: must open with `---` frontmatter on line 1',
    ];
  }
  final end = lines.indexOf('---', 1);
  if (end < 0) return [...problems, '$rel/SKILL.md: frontmatter is not closed'];
  final front = lines.sublist(1, end);
  String? field(String key) {
    for (final line in front) {
      if (line.startsWith('$key:')) {
        return line.substring(key.length + 1).trim();
      }
    }
    return null;
  }

  final name = field('name');
  if (name != skillName) {
    problems.add('$rel/SKILL.md: name `$name` must equal the directory name');
  }
  final prefixes = {'$packageName-', '${packageName.replaceAll('_', '-')}-'};
  if (!prefixes.any(skillName.startsWith)) {
    problems.add(
      '$rel: directory name must start with `$packageName-`; '
      'the skills CLI skips it otherwise',
    );
  }
  final description = field('description');
  if (description == null || description.isEmpty) {
    problems.add('$rel/SKILL.md: empty description');
  }
  return problems;
}

List<String> _checkLinks(Directory root, File md, String text) {
  final problems = <String>[];
  final withoutCode = text.replaceAll(RegExp(r'```.*?```', dotAll: true), '');
  for (final match in RegExp(r'\]\(([^)\s]+)\)').allMatches(withoutCode)) {
    final target = match.group(1)!.split('#').first;
    if (target.isEmpty ||
        target.contains('://') ||
        target.startsWith('mailto:')) {
      continue;
    }
    final resolved = File('${md.parent.path}/$target');
    if (!resolved.existsSync() && !Directory(resolved.path).existsSync()) {
      problems.add('${_relative(root, md.path)}: broken link `$target`');
    }
  }
  return problems;
}

/// Joins every ```dart block into one library, imports first. Returns null
/// when the file has no Dart blocks.
String? _joinDartBlocks(String text) {
  final blocks = RegExp(
    r'^```dart[^\n]*\n(.*?)^```',
    multiLine: true,
    dotAll: true,
  ).allMatches(text).map((m) => m.group(1)!).toList();
  if (blocks.isEmpty) return null;
  final imports = <String>{"import 'package:rpc_dart/rpc_dart.dart';"};
  final body = <String>[];
  for (final block in blocks) {
    for (final line in block.split('\n')) {
      if (line.startsWith('import ')) {
        imports.add(line);
      } else {
        body.add(line);
      }
    }
  }
  final hasMain = body.any((l) => RegExp(r'^\S.*\bmain\(').hasMatch(l));
  return [
    '// Generated by tool/check_skills.dart; deleted after the check.',
    ...imports.toList()..sort(),
    '',
    ...body,
    if (!hasMain) 'void main() {}',
    '',
  ].join('\n');
}

String _packageName(Directory packageDir) {
  final pubspec = File('${packageDir.path}/pubspec.yaml').readAsLinesSync();
  final line = pubspec.firstWhere((l) => l.startsWith('name:'));
  return line.substring('name:'.length).trim();
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _relative(Directory from, String path) {
  final prefix = '${from.path}${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}
