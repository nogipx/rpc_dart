// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Line-level mutation testing for one library file of this repository.
///
/// Usage (from the repo root):
///   fvm dart run tool/mutants/mutants.dart --file <lib file>
///       --tests <test file or dir>[,<more>] [--limit N] [--timeout SECONDS]
///       [--report <path>] [--list]
///
/// Each mutant changes one operator on one line. The tests are run against
/// it; a mutant the tests still pass on is SURVIVED, and it marks a line no
/// test constrains. A survivor is a hypothesis for a round, not a finding.
///
/// The main working tree is never written to. Everything happens in a
/// detached git worktree of HEAD under the system temp directory, which is
/// removed at the end, also on an exception, Ctrl-C or SIGTERM. A worktree
/// left behind by a run that was killed outright is removed by the next run.
///
/// Not part of any gate: it is slow by construction (one full test run per
/// mutant) and a survivor says nothing until a round looks at it.
Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on FormatException catch (e) {
    stderr
      ..writeln('error: ${e.message}')
      ..writeln()
      ..writeln(_usage);
    exit(64);
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  exitCode = await _Run(options).call();
}

const _usage = '''
Mutation testing for one file: which lines can change without a test failing.

  fvm dart run tool/mutants/mutants.dart --file <lib file> --tests <paths>

  --file <path>       Dart file to mutate (repo-relative or absolute).
  --tests <paths>     Comma-separated test files or directories, all in the
                      package that owns --file.
  --limit <N>         Run at most N mutants, sampled evenly across the file.
                      Default: as many as fit in ~15 minutes at the measured
                      baseline test time.
  --timeout <sec>     Per-mutant timeout. Default: 3x the baseline, min 60.
  --report <path>     Also write the results as JSON.
  --list              Print every mutant and exit; runs nothing.
  -h, --help          This text.

Runs in a temporary git worktree of HEAD; the main tree is never written to.
A SURVIVED mutant is a target for a round, not a finding.''';

// ── Mutation operators ───────────────────────────────────────────────────────

/// One mutation operator.
///
/// [pattern] runs against a line whose comments and string literals are
/// blanked out, so it can only ever match code. Each match is one mutant: the
/// matched range is replaced by [mutate]'s result in the ORIGINAL line.
final class _Operator {
  _Operator(this.name, String pattern, this.mutate) : pattern = RegExp(pattern);

  final String name;
  final RegExp pattern;
  final String Function(RegExpMatch match) mutate;
}

/// A binary operator token: whitespace before, whitespace or end of line
/// after. `dart format` spaces every binary operator and never a generic
/// bracket, so `List<int>`, `Map<K, V> x`, `=>` and `>>` cannot match.
String _binary(String alternatives) => '(?<=\\s)(?:$alternatives)(?=\\s|\$)';

String _swap(Map<String, String> table, RegExpMatch m) => table[m[0]]!;

/// THE operator table. To add an operator, add a row.
final List<_Operator> _operators = [
  _Operator(
    'relational',
    _binary('<=|>=|<|>'),
    (m) => _swap(const {'<': '<=', '<=': '<', '>': '>=', '>=': '>'}, m),
  ),
  _Operator(
    'equality',
    _binary('==|!='),
    (m) => _swap(const {'==': '!=', '!=': '=='}, m),
  ),
  _Operator(
    'logical',
    _binary(r'&&|\|\|'),
    (m) => _swap(const {'&&': '||', '||': '&&'}, m),
  ),
  _Operator(
    'boolean',
    r'(?<![\w$.])(?:true|false)(?![\w$])',
    (m) => _swap(const {'true': 'false', 'false': 'true'}, m),
  ),
  // `if (!x)` -> `if (x)`. Only the simple leading form; `!=` is equality.
  _Operator('negation', r'(?<=\bif \()!(?!=)', (m) => ''),
  // An integer literal on the right of a comparison: `n` -> `n + 1`.
  _Operator(
    'off-by-one',
    r'(?<=\s(?:<=|>=|<|>|==|!=) )\d+(?![\w.])',
    (m) => '${int.parse(m[0]!) + 1}',
  ),
  // A line that is exactly a guard: `return;`, `continue;`, `break;`, or a
  // single-line `if (...) return ...;`. Deleted, indentation kept.
  _Operator(
    'delete-guard',
    r'^(\s*)(?:return;|continue;|break;|if \(.*\) return\b[^;]*;)\s*$',
    (m) => m[1]!,
  ),
];

/// Lines that are never mutated, matched against the blanked line.
final _skipLine = RegExp(r'^\s*(?:import|export|part|library)\b');

final class _Mutant {
  _Mutant(this.line, this.operator, this.original, this.mutated);

  final int line;
  final String operator;
  final String original;
  final String mutated;

  String status = 'pending';
  int millis = 0;

  Map<String, Object?> toJson() => {
    'line': line,
    'operator': operator,
    'original': original.trim(),
    'mutated': mutated.trim(),
    'status': status,
    'millis': millis,
  };
}

/// Every mutant of [source], in line order, one per operator match.
List<_Mutant> _mutantsOf(String source) {
  final lines = source.split('\n');
  final masked = _maskNonCode(source).split('\n');
  final result = <_Mutant>[];
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final code = masked[i];
    if (code.trim().isEmpty || _skipLine.hasMatch(code)) continue;
    final original = lines[i];
    for (final op in _operators) {
      for (final m in op.pattern.allMatches(code)) {
        final mutated = original.replaceRange(m.start, m.end, op.mutate(m));
        if (mutated == original || !seen.add('$i\u0000$mutated')) continue;
        result.add(_Mutant(i + 1, op.name, original, mutated));
      }
    }
  }
  return result;
}

/// [source] with every character that is not code -- comments, and string
/// literals including their `${...}` interpolations -- replaced by a space.
/// Length and newlines are preserved, so offsets and line numbers carry over.
String _maskNonCode(String source) {
  final out = source.codeUnits.toList();
  final n = source.length;
  void blank(int from, int to) {
    for (var k = from; k < to && k < n; k++) {
      if (out[k] != 0x0A) out[k] = 0x20;
    }
  }

  bool at(String token, int i) => source.startsWith(token, i);
  bool identChar(String c) => RegExp(r'[\w$]').hasMatch(c);

  // The bottom frame is plain code; anything above it is inside a string.
  final stack = <_Frame>[_Frame.code(interpolation: false)];
  var i = 0;
  while (i < n) {
    final top = stack.last;
    if (top.isCode) {
      final c = source[i];
      if (at('//', i)) {
        final end = source.indexOf('\n', i);
        final stop = end < 0 ? n : end;
        blank(i, stop);
        i = stop;
        continue;
      }
      if (at('/*', i)) {
        var depth = 1;
        var j = i + 2;
        while (j < n && depth > 0) {
          if (at('/*', j)) {
            depth++;
            j += 2;
          } else if (at('*/', j)) {
            depth--;
            j += 2;
          } else {
            j++;
          }
        }
        blank(i, j);
        i = j;
        continue;
      }
      if (c == "'" || c == '"') {
        final raw =
            i > 0 &&
            (source[i - 1] == 'r' || source[i - 1] == 'R') &&
            (i < 2 || !identChar(source[i - 2]));
        final quote = at(c * 3, i) ? c * 3 : c;
        stack.add(_Frame.string(quote, raw: raw));
        blank(raw ? i - 1 : i, i + quote.length);
        i += quote.length;
        continue;
      }
      if (c == '{') {
        top.braces++;
      } else if (c == '}') {
        if (top.interpolation && top.braces == 0) {
          stack.removeLast();
          blank(i, i + 1);
          i++;
          continue;
        }
        top.braces--;
      }
      if (stack.length > 1) blank(i, i + 1);
      i++;
      continue;
    }
    if (!top.raw && source[i] == r'\') {
      blank(i, i + 2);
      i += 2;
      continue;
    }
    if (!top.raw && at(r'${', i)) {
      stack.add(_Frame.code(interpolation: true));
      blank(i, i + 2);
      i += 2;
      continue;
    }
    if (at(top.quote, i)) {
      blank(i, i + top.quote.length);
      i += top.quote.length;
      stack.removeLast();
      continue;
    }
    blank(i, i + 1);
    i++;
  }
  return String.fromCharCodes(out);
}

final class _Frame {
  _Frame.code({required this.interpolation})
    : isCode = true,
      quote = '',
      raw = false;
  _Frame.string(this.quote, {required this.raw})
    : isCode = false,
      interpolation = false;

  final bool isCode;
  final bool interpolation;
  final String quote;
  final bool raw;
  int braces = 0;
}

// ── Options ──────────────────────────────────────────────────────────────────

final class _Options {
  _Options({
    required this.file,
    required this.tests,
    required this.limit,
    required this.timeout,
    required this.report,
    required this.list,
    required this.help,
  });

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    final flags = <String>{};
    const valued = {'file', 'tests', 'limit', 'timeout', 'report'};
    const boolean = {'list', 'help'};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-h') {
        flags.add('help');
        continue;
      }
      if (!arg.startsWith('--')) {
        throw FormatException('unexpected argument "$arg"');
      }
      final eq = arg.indexOf('=');
      final name = arg.substring(2, eq < 0 ? arg.length : eq);
      if (boolean.contains(name) && eq < 0) {
        flags.add(name);
      } else if (valued.contains(name)) {
        if (eq >= 0) {
          values[name] = arg.substring(eq + 1);
        } else if (i + 1 < args.length) {
          values[name] = args[++i];
        } else {
          throw FormatException('--$name needs a value');
        }
      } else {
        throw FormatException('unknown option "$arg"');
      }
    }
    if (flags.contains('help')) {
      return _Options(
        file: '',
        tests: const [],
        limit: null,
        timeout: null,
        report: null,
        list: false,
        help: true,
      );
    }
    final file = values['file'];
    if (file == null || file.isEmpty) {
      throw const FormatException('--file is required');
    }
    final tests = (values['tests'] ?? '')
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (tests.isEmpty && !flags.contains('list')) {
      throw const FormatException('--tests is required');
    }
    int? positive(String name) {
      final raw = values[name];
      if (raw == null) return null;
      final v = int.tryParse(raw);
      if (v == null || v <= 0) {
        throw FormatException('--$name must be a positive integer');
      }
      return v;
    }

    return _Options(
      file: file,
      tests: tests,
      limit: positive('limit'),
      timeout: positive('timeout'),
      report: values['report'],
      list: flags.contains('list'),
      help: false,
    );
  }

  final String file;
  final List<String> tests;
  final int? limit;
  final int? timeout;
  final String? report;
  final bool list;
  final bool help;
}

// ── The run ──────────────────────────────────────────────────────────────────

/// Marker in the temp directory name; `<pid>` after it identifies the owner.
const _marker = 'rpc_dart_mutants_';

/// Wall-time budget the default --limit aims for.
const _budget = Duration(minutes: 15);

final class _Run {
  _Run(this.options);

  final _Options options;

  late final String _root;
  Directory? _tempDir;
  String? _worktree;
  Process? _child;
  bool _cleanedUp = false;

  Future<int> call() async {
    final rootResult = Process.runSync('git', ['rev-parse', '--show-toplevel']);
    if (rootResult.exitCode != 0) {
      stderr.writeln('error: not inside a git repository');
      return 2;
    }
    _root = (rootResult.stdout as String).trim();

    final fileAbs = _absolute(options.file);
    if (!File(fileAbs).existsSync()) {
      stderr.writeln('error: no such file: ${options.file}');
      return 2;
    }
    final source = File(fileAbs).readAsStringSync();
    final all = _mutantsOf(source);
    final fileRel = _relativeTo(_root, fileAbs);

    if (options.list) {
      for (final m in all) {
        stdout.writeln(_describe(fileRel ?? options.file, m));
      }
      stdout.writeln('${all.length} mutants');
      return 0;
    }
    if (fileRel == null) {
      stderr.writeln('error: ${options.file} is outside the repository');
      return 2;
    }

    final packageAbs = _owningPackage(fileAbs);
    if (packageAbs == null) {
      stderr.writeln('error: no pubspec.yaml above ${options.file}');
      return 2;
    }
    final packageRel = _relativeTo(_root, packageAbs)!;
    final testsInPackage = <String>[];
    for (final t in options.tests) {
      final abs = _absolute(t);
      final rel = _relativeTo(packageAbs, abs);
      if (rel == null || rel.isEmpty) {
        stderr.writeln('error: test path $t is not inside $packageRel');
        return 2;
      }
      testsInPackage.add(rel);
    }

    final diff = Process.runSync('git', [
      '-C',
      _root,
      'diff',
      '--quiet',
      'HEAD',
      '--',
      fileRel,
      for (final t in testsInPackage) '$packageRel/$t',
    ]);
    if (diff.exitCode != 0) {
      stdout.writeln(
        'note: the file or tests differ from HEAD in the working tree; '
        'the run uses the COMMITTED version.',
      );
    }

    final signals = <StreamSubscription<ProcessSignal>>[
      for (final s in [ProcessSignal.sigint, ProcessSignal.sigterm])
        s.watch().listen((_) => _interrupted()),
    ];
    final started = DateTime.now();
    try {
      _cleanStale();
      _createWorktree();
      final wt = _worktree!;
      final wtPackage = '$wt/$packageRel';
      final wtFile = '$wt/$fileRel';
      for (final t in testsInPackage) {
        final p = '$wtPackage/$t';
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound) {
          stderr.writeln(
            'error: $packageRel/$t is not in HEAD; commit it first '
            '(the run uses a worktree of HEAD)',
          );
          return 2;
        }
      }

      stdout.writeln('pub get --offline in the worktree ...');
      final get = await _exec(['fvm', 'dart', 'pub', 'get', '--offline'], wt);
      if (get.exitCode != 0) {
        stderr
          ..writeln(get.output)
          ..writeln('error: pub get --offline failed in the worktree');
        return 2;
      }

      final testCmd = [
        'fvm',
        'dart',
        'test',
        '--reporter',
        'failures-only',
        ...testsInPackage,
      ];
      stdout.writeln('baseline: ${testCmd.join(' ')}  (in $packageRel)');
      final baseline = await _exec(testCmd, wtPackage);
      if (baseline.exitCode != 0) {
        stderr
          ..writeln(baseline.output)
          ..writeln(
            'error: the tests fail WITHOUT any mutation (exit '
            '${baseline.exitCode}); every mutant would read as killed. Aborting.',
          );
        return 1;
      }
      final base = baseline.elapsed;
      final timeout = Duration(
        seconds:
            options.timeout ??
            (base.inSeconds * 3 < 60 ? 60 : base.inSeconds * 3),
      );
      final fit = _budget.inMilliseconds ~/ (base.inMilliseconds + 1);
      final limit = options.limit ?? (fit < 1 ? 1 : fit);
      final chosen = _sample(all, limit);
      final estimate = Duration(
        milliseconds: base.inMilliseconds * chosen.length,
      );
      stdout
        ..writeln(
          'baseline green in ${_secs(base)}; ${all.length} mutants in the '
          'file, running ${chosen.length}'
          '${chosen.length < all.length ? ' (sampled evenly)' : ''}',
        )
        ..writeln(
          'estimate: ~${_mins(estimate)} '
          '(${chosen.length} x ${_secs(base)}); timeout per mutant '
          '${_secs(timeout)}',
        );

      for (var k = 0; k < chosen.length; k++) {
        final m = chosen[k];
        File(wtFile).writeAsStringSync(_apply(source, m));
        try {
          final r = await _exec(testCmd, wtPackage, timeout: timeout);
          m.millis = r.elapsed.inMilliseconds;
          m.status = r.timedOut
              ? 'timeout'
              : _compileError.hasMatch(r.output)
              ? 'stillborn'
              : r.exitCode == 0
              ? 'survived'
              : 'killed';
        } finally {
          File(wtFile).writeAsStringSync(source);
        }
        stdout.writeln(
          '[${k + 1}/${chosen.length}] ${m.status.toUpperCase().padRight(9)} '
          '${_describe(fileRel, m)}  (${_secs(Duration(milliseconds: m.millis))})',
        );
      }

      final wall = DateTime.now().difference(started);
      _summarise(fileRel, packageRel, testsInPackage, all, chosen, base, wall);
      return 0;
    } finally {
      _cleanup();
      for (final s in signals) {
        await s.cancel();
      }
    }
  }

  void _summarise(
    String fileRel,
    String packageRel,
    List<String> tests,
    List<_Mutant> all,
    List<_Mutant> run,
    Duration baseline,
    Duration wall,
  ) {
    int count(String s) => run.where((m) => m.status == s).length;
    final survivors = run.where((m) => m.status == 'survived').toList();
    final timeouts = run.where((m) => m.status == 'timeout').toList();
    stdout
      ..writeln()
      ..writeln('file       $fileRel')
      ..writeln('mutants    ${run.length} run of ${all.length}')
      ..writeln('killed     ${count('killed')}')
      ..writeln('survived   ${count('survived')}')
      ..writeln('stillborn  ${count('stillborn')}  (did not compile)')
      ..writeln('timeouts   ${count('timeout')}  (counted as killed)')
      ..writeln('wall time  ${_mins(wall)}');
    if (timeouts.isNotEmpty) {
      stdout.writeln('\nTIMEOUT');
      for (final m in timeouts) {
        stdout.writeln('  ${_describe(fileRel, m)}');
      }
    }
    stdout.writeln('\nSURVIVED${survivors.isEmpty ? ': none' : ''}');
    for (final m in survivors) {
      stdout.writeln('  ${_describe(fileRel, m)}');
    }

    final report = options.report;
    if (report != null) {
      final head = Process.runSync('git', ['-C', _root, 'rev-parse', 'HEAD']);
      final json = {
        'file': fileRel,
        'package': packageRel,
        'tests': tests,
        'head': (head.stdout as String).trim(),
        'summary': {
          'mutantsInFile': all.length,
          'mutants': run.length,
          'killed': count('killed'),
          'survived': count('survived'),
          'stillborn': count('stillborn'),
          'timeouts': count('timeout'),
          'baselineMillis': baseline.inMilliseconds,
          'wallMillis': wall.inMilliseconds,
        },
        'survived': [for (final m in survivors) m.toJson()],
        'mutants': [for (final m in run) m.toJson()],
      };
      File(_absolute(report))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(json)}\n',
        );
      stdout.writeln('\nreport written to $report');
    }
  }

  // ── Worktree lifecycle ─────────────────────────────────────────────────────

  /// Removes worktrees earlier runs left behind, skipping a live concurrent run.
  void _cleanStale() {
    final list = Process.runSync('git', [
      '-C',
      _root,
      'worktree',
      'list',
      '--porcelain',
    ]);
    final ownerPid = RegExp('$_marker(\\d+)_');
    var found = false;
    for (final line in (list.stdout as String).split('\n')) {
      if (!line.startsWith('worktree ')) continue;
      final path = line.substring('worktree '.length);
      final m = ownerPid.firstMatch(path);
      if (m == null) continue;
      final owner = int.parse(m[1]!);
      if (owner != pid && _alive(owner)) continue;
      found = true;
      stdout.writeln('a previous run left a worktree behind: $path; removing');
      Process.runSync('git', [
        '-C',
        _root,
        'worktree',
        'remove',
        '--force',
        '--force',
        path,
      ]);
      final parent = Directory(path).parent;
      if (parent.path.contains(_marker) && parent.existsSync()) {
        parent.deleteSync(recursive: true);
      }
    }
    if (found) Process.runSync('git', ['-C', _root, 'worktree', 'prune']);
  }

  void _createWorktree() {
    final temp = Directory.systemTemp.createTempSync('$_marker${pid}_');
    _tempDir = temp;
    final wt = '${temp.resolveSymbolicLinksSync()}/wt';
    final add = Process.runSync('git', [
      '-C',
      _root,
      'worktree',
      'add',
      '--detach',
      wt,
      'HEAD',
    ]);
    if (add.exitCode != 0) {
      throw StateError('git worktree add failed: ${add.stderr}');
    }
    _worktree = wt;
    stdout.writeln('worktree: $wt');
  }

  /// Idempotent and synchronous, so it also runs from a signal handler.
  void _cleanup() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    final wt = _worktree;
    if (wt != null) {
      final r = Process.runSync('git', [
        '-C',
        _root,
        'worktree',
        'remove',
        '--force',
        '--force',
        wt,
      ]);
      if (r.exitCode != 0) {
        stderr.writeln('warning: git worktree remove failed: ${r.stderr}');
      }
    }
    final temp = _tempDir;
    if (temp != null && temp.existsSync()) temp.deleteSync(recursive: true);
    if (wt != null) {
      Process.runSync('git', ['-C', _root, 'worktree', 'prune']);
      stdout.writeln('worktree removed');
    }
  }

  void _interrupted() {
    stderr.writeln('\ninterrupted; removing the worktree');
    final child = _child;
    if (child != null) _killTree(child.pid);
    _cleanup();
    exit(130);
  }

  // ── Processes ──────────────────────────────────────────────────────────────

  Future<_Result> _exec(
    List<String> cmd,
    String cwd, {
    Duration? timeout,
  }) async {
    final watch = Stopwatch()..start();
    final p = await Process.start(
      cmd.first,
      cmd.sublist(1),
      workingDirectory: cwd,
    );
    _child = p;
    final out = StringBuffer();
    const decoder = Utf8Decoder(allowMalformed: true);
    final drains = [
      p.stdout.transform(decoder).listen(out.write).asFuture<void>(),
      p.stderr.transform(decoder).listen(out.write).asFuture<void>(),
    ];
    var timedOut = false;
    int code;
    try {
      code = timeout == null
          ? await p.exitCode
          : await p.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      _killTree(p.pid);
      code = await p.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => -1,
      );
    }
    // An orphaned grandchild can hold a pipe open; do not wait on it forever.
    await Future.wait(
      drains,
    ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    _child = null;
    watch.stop();
    return _Result(code, out.toString(), watch.elapsed, timedOut);
  }

  /// SIGKILLs [root] and every descendant: `fvm` runs `dart`, which runs the
  /// test runner, and killing only the top leaves the rest running.
  static void _killTree(int root) {
    final all = <int>[root];
    for (var i = 0; i < all.length; i++) {
      final r = Process.runSync('pgrep', ['-P', '${all[i]}']);
      all.addAll(
        (r.stdout as String)
            .split('\n')
            .map((l) => int.tryParse(l.trim()))
            .whereType<int>(),
      );
    }
    for (final p in all) {
      Process.killPid(p, ProcessSignal.sigkill);
    }
  }

  static bool _alive(int pid) =>
      Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  // ── Paths ──────────────────────────────────────────────────────────────────

  String _absolute(String path) {
    final abs = File(path).isAbsolute
        ? path
        : '${Directory.current.path}/$path';
    return File(abs).absolute.uri.normalizePath().toFilePath();
  }

  /// [path] relative to [base], or null when it is not under it.
  static String? _relativeTo(String base, String path) {
    final b = Directory(base).absolute.uri.normalizePath().toFilePath();
    final prefix = b.endsWith('/') ? b : '$b/';
    final p = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    if (p == prefix.substring(0, prefix.length - 1)) return '';
    return p.startsWith(prefix) ? p.substring(prefix.length) : null;
  }

  static String? _owningPackage(String fileAbs) {
    var dir = File(fileAbs).parent;
    while (true) {
      if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
      final up = dir.parent;
      if (up.path == dir.path) return null;
      dir = up;
    }
  }
}

final class _Result {
  _Result(this.exitCode, this.output, this.elapsed, this.timedOut);

  final int exitCode;
  final String output;
  final Duration elapsed;
  final bool timedOut;
}

/// A front-end compile error, as `dart test` prints it for a file that fails
/// to load: `path/file.dart:12:5: Error: ...`.
final _compileError = RegExp(r'\.dart:\d+:\d+: Error: ');

/// [count] mutants spread evenly over [all], in line order.
List<_Mutant> _sample(List<_Mutant> all, int count) {
  if (count >= all.length) return all;
  return [for (var i = 0; i < count; i++) all[i * all.length ~/ count]];
}

String _apply(String source, _Mutant m) {
  final lines = source.split('\n');
  lines[m.line - 1] = m.mutated;
  return lines.join('\n');
}

String _describe(String file, _Mutant m) =>
    '$file:${m.line}  ${m.original.trim()}  ->  ${m.mutated.trim()}'
    '  [${m.operator}]';

String _secs(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

String _mins(Duration d) =>
    '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
