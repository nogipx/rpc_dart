import 'dart:io';

import 'package:args/args.dart';
import 'package:qr/qr.dart';
import 'package:qr_stl_generator/qr_stl_generator.dart';

void main(List<String> arguments) {
  final ArgParser parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    )
    ..addOption(
      'data',
      abbr: 'd',
      help:
          'Literal text to encode into the QR code. Mutually exclusive with --input.',
    )
    ..addOption(
      'input',
      abbr: 'i',
      help: 'Read QR payload text from the provided file path.',
    )
    ..addOption(
      'mode',
      abbr: 'm',
      defaultsTo: 'single-swap',
      allowed: <String>['single-swap', 'dual-stl', 'dual-bundle'],
      help:
          'Color-handling strategy: single-swap (one STL), dual-stl (two STLs), or dual-bundle (inlay base + aligned QR plate in one STL).',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help:
          'Output path. In single-swap mode defaults to qr_single_swap.stl. In dual-stl mode it is used as a prefix (default qr_dual).',
    )
    ..addOption(
      'module-size',
      defaultsTo: '1.0',
      help: 'Edge length of a single QR module (square) in millimetres.',
    )
    ..addOption(
      'base-height',
      defaultsTo: '0.6',
      help: 'Thickness of the base plate (colour A) in millimetres.',
    )
    ..addOption(
      'raise-height',
      defaultsTo: '0.4',
      help: 'Additional height for dark modules (colour B) in millimetres.',
    )
    ..addOption(
      'margin',
      defaultsTo: '2',
      help: 'Quiet zone around the QR code, expressed in module units.',
    )
    ..addOption(
      'error-correction',
      abbr: 'e',
      defaultsTo: 'M',
      allowed: <String>['L', 'M', 'Q', 'H'],
      help: 'QR error correction level.',
    )
    ..addFlag(
      'inlay',
      defaultsTo: false,
      help:
          'Generate inlay-style dual STLs where modules sit flush with the base (dual-stl or dual-bundle modes).',
    )
    ..addOption(
      'bundle-gap',
      defaultsTo: '2',
      help:
          'Extra spacing in millimetres between the base and QR plate when using dual-bundle mode (defaults to two module widths).',
    );

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    _printUsage(parser, error: error.message);
    exitCode = 64;
    return;
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final String? dataArg = results['data'] as String?;
  final String? inputPath = results['input'] as String?;

  if (dataArg != null && inputPath != null) {
    _printUsage(parser,
        error: 'Only one of --data or --input can be provided.');
    exitCode = 64;
    return;
  }

  String? payload = dataArg;
  if (payload == null && inputPath != null) {
    try {
      payload = File(inputPath).readAsStringSync();
    } on IOException catch (error) {
      stderr.writeln('Failed to read input file: $error');
      exitCode = 74;
      return;
    }
  }

  if (payload == null || payload.isEmpty) {
    _printUsage(parser,
        error: 'QR payload is empty. Provide --data or --input.');
    exitCode = 64;
    return;
  }

  final double? moduleSize = double.tryParse(results['module-size'] as String);
  final double? baseHeight = double.tryParse(results['base-height'] as String);
  final double? raiseHeight =
      double.tryParse(results['raise-height'] as String);
  final int? margin = int.tryParse(results['margin'] as String);
  final String bundleGapRaw = results['bundle-gap'] as String;
  final double? bundleGap = double.tryParse(bundleGapRaw);

  if (moduleSize == null || moduleSize <= 0) {
    stderr.writeln('Invalid --module-size value.');
    exitCode = 64;
    return;
  }
  if (baseHeight == null || baseHeight <= 0) {
    stderr.writeln('Invalid --base-height value.');
    exitCode = 64;
    return;
  }
  if (raiseHeight == null || raiseHeight < 0) {
    stderr.writeln('Invalid --raise-height value.');
    exitCode = 64;
    return;
  }
  if (margin == null || margin < 0) {
    stderr.writeln('Invalid --margin value.');
    exitCode = 64;
    return;
  }
  if (bundleGap == null) {
    stderr.writeln('Invalid --bundle-gap value.');
    exitCode = 64;
    return;
  }

  final bool inlay = results['inlay'] as bool;
  final String mode = results['mode'] as String;

  if (inlay && mode == 'single-swap') {
    stderr.writeln(
        'Inlay geometry is only supported in dual-stl or dual-bundle modes.');
    exitCode = 64;
    return;
  }

  final bool bundleMode = mode == 'dual-bundle';
  final bool needsInlayGeometry = inlay || bundleMode;

  if (needsInlayGeometry && raiseHeight == 0) {
    stderr.writeln('Inlay geometry requires a positive --raise-height.');
    exitCode = 64;
    return;
  }
  if (needsInlayGeometry &&
      raiseHeight != null &&
      baseHeight != null &&
      baseHeight <= raiseHeight) {
    stderr.writeln('Inlay geometry requires --base-height > --raise-height.');
    exitCode = 64;
    return;
  }
  if (bundleMode && bundleGap < 0) {
    stderr.writeln('--bundle-gap cannot be negative.');
    exitCode = 64;
    return;
  }

  final int errorLevel =
      _mapErrorCorrection(results['error-correction'] as String);

  final QrStlConfig config = QrStlConfig(
    data: payload,
    moduleSize: moduleSize,
    baseHeight: baseHeight,
    raiseHeight: raiseHeight,
    margin: margin,
    errorCorrectLevel: errorLevel,
    inlay: needsInlayGeometry,
  );

  final QrStlGenerator generator = QrStlGenerator(config);

  if (mode == 'single-swap') {
    final String outputPath =
        (results['output'] as String?) ?? 'qr_single_swap.stl';
    final String solidName =
        _solidNameFromPath(outputPath, fallback: 'qr_single_swap');
    final String stl = generator.generateSingleSwap(solidName: solidName);
    _writeFile(outputPath, stl);
    stdout.writeln('Generated single-swap STL: $outputPath');
    stdout.writeln(
        'Pause the print at Z=${baseHeight.toStringAsFixed(3)}mm to swap filament.');
  } else if (mode == 'dual-stl') {
    final String prefix = (results['output'] as String?) ?? 'qr_dual';
    final String basePath = '${prefix}_base_A.stl';
    final String modulePath = '${prefix}_qr_B.stl';
    final DualStlResult result = generator.generateDualStl(
      baseSolidName: _solidNameFromPath(basePath, fallback: 'qr_base_A'),
      moduleSolidName: _solidNameFromPath(modulePath, fallback: 'qr_qr_B'),
    );
    _writeFile(basePath, result.base);
    _writeFile(modulePath, result.modules);
    stdout.writeln('Generated dual-STL set:');
    stdout.writeln('  Base (colour A): $basePath');
    stdout.writeln('  Modules (colour B): $modulePath');
    stdout.writeln(
      'Import both files as one multi-part object in your slicer (merge by origin) and assign separate colours/materials.',
    );
  } else {
    final String outputPath =
        (results['output'] as String?) ?? 'qr_inlay_bundle.stl';
    final String solidName =
        _solidNameFromPath(outputPath, fallback: 'qr_inlay_bundle');
    final String stl = generator.generateInlayBundle(
      solidName: solidName,
      spacing: bundleGap,
    );
    _writeFile(outputPath, stl);
    stdout.writeln('Generated dual-bundle STL: $outputPath');
    stdout.writeln(
      'Print the pocketed base and QR plate together. The base STL is mirrored so that after flipping it face-down it matches the plate—just flip and press the base onto the QR plate.',
    );
  }
}

void _printUsage(ArgParser parser, {String? error}) {
  if (error != null) {
    stderr.writeln(error);
  }
  stderr.writeln('Usage: dart run qr_stl_generator --data "Hello" [options]');
  stderr.writeln(parser.usage);
}

int _mapErrorCorrection(String level) {
  switch (level.toUpperCase()) {
    case 'L':
      return QrErrorCorrectLevel.L;
    case 'M':
      return QrErrorCorrectLevel.M;
    case 'Q':
      return QrErrorCorrectLevel.Q;
    case 'H':
      return QrErrorCorrectLevel.H;
  }
  return QrErrorCorrectLevel.M;
}

String _solidNameFromPath(String path, {required String fallback}) {
  final String filename = path.split(Platform.pathSeparator).last;
  if (filename.isEmpty) {
    return fallback;
  }
  final int dotIndex = filename.lastIndexOf('.');
  if (dotIndex <= 0) {
    return filename;
  }
  final String candidate = filename.substring(0, dotIndex);
  return candidate.isEmpty ? fallback : candidate;
}

void _writeFile(String path, String contents) {
  final File file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}
