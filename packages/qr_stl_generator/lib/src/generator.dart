
import 'dart:math' as math;

import 'package:qr/qr.dart';

import 'config.dart';
import 'stl_builder.dart';

class QrStlGenerator {
  QrStlGenerator(this.config);

  final QrStlConfig config;

  String generateSingleSwap({String solidName = 'qr_single_swap'}) {
    if (config.inlay) {
      throw StateError('Inlay mode requires dual-stl output.');
    }
    final _QrMatrix matrix = _createMatrix();
    final StlBuilder builder = StlBuilder(name: solidName);

    _addBaseShell(builder, matrix.totalSize, config.baseHeight);

    for (int row = 0; row < matrix.size; row++) {
      for (int col = 0; col < matrix.size; col++) {
        final _Cell cell = matrix.cellAt(row, col);
        if (cell.isDark) {
          _addRaisedTop(builder, cell.bounds, config.baseHeight + config.raiseHeight);
          _addModuleSides(builder, matrix, row, col, cell.bounds, config.baseHeight,
              config.baseHeight + config.raiseHeight);
        } else {
          _addRaisedTop(builder, cell.bounds, config.baseHeight);
        }
      }
    }

    return builder.toString();
  }

  DualStlResult generateDualStl({
    String baseSolidName = 'qr_base_A',
    String moduleSolidName = 'qr_qr_B',
  }) {
    final _QrMatrix matrix = _createMatrix();

    final StlBuilder baseBuilder = StlBuilder(name: baseSolidName);
    final StlBuilder moduleBuilder = StlBuilder(name: moduleSolidName);

    if (config.inlay) {
      final double cavityFloor = config.baseHeight - config.raiseHeight;
      if (cavityFloor <= 0) {
        throw StateError(
          'Inlay mode requires baseHeight (${config.baseHeight}) to exceed '
          'raiseHeight (${config.raiseHeight}) so the pocket leaves a floor. '
          'Increase baseHeight or reduce raiseHeight.',
        );
      }

      for (int row = 0; row < matrix.size; row++) {
        for (int col = 0; col < matrix.size; col++) {
          final _Cell cell = matrix.cellAt(row, col);
          final _Bounds bounds = cell.bounds;
          final double cellTop =
              cell.isDark ? cavityFloor : config.baseHeight;
          _addBaseCell(
            baseBuilder,
            matrix,
            row,
            col,
            bounds,
            0,
            cellTop,
            config.baseHeight,
            cavityFloor,
          );
          if (cell.isDark) {
            final double bottom = cavityFloor;
            final double top = config.baseHeight;
            _addTopFace(moduleBuilder, bounds, top);
            _addBottomFace(moduleBuilder, bounds, bottom);
            _addModuleSides(
              moduleBuilder,
              matrix,
              row,
              col,
              bounds,
              bottom,
              top,
            );
          }
        }
      }
    } else {
      _addFullBase(baseBuilder, matrix.totalSize, config.baseHeight);
      for (int row = 0; row < matrix.size; row++) {
        for (int col = 0; col < matrix.size; col++) {
          final _Cell cell = matrix.cellAt(row, col);
          if (!cell.isDark) {
            continue;
          }
          final _Bounds bounds = cell.bounds;
          final double bottom = config.baseHeight;
          final double top = config.baseHeight + config.raiseHeight;
          _addTopFace(moduleBuilder, bounds, top);
          _addBottomFace(moduleBuilder, bounds, bottom);
          _addModuleSides(moduleBuilder, matrix, row, col, bounds, bottom, top);
        }
      }
    }

    return DualStlResult(
      base: baseBuilder.toString(),
      modules: moduleBuilder.toString(),
    );
  }

  String generateInlayBundle({
    String solidName = 'qr_inlay_bundle',
    double spacing = 0,
  }) {
    if (!config.inlay) {
      throw StateError('Inlay bundle requires --inlay configuration.');
    }

    final _QrMatrix matrix = _createMatrix();
    // Mirror the base grid so flipping the printed base restores the original
    // QR orientation while the module plate stays unmirrored.
    final _QrMatrix mirroredBase = matrix.mirroredRows();
    final StlBuilder builder = StlBuilder(name: solidName);

    final double cavityFloor = config.baseHeight - config.raiseHeight;
    if (cavityFloor <= 0) {
      throw StateError(
        'Inlay bundle requires baseHeight (${config.baseHeight}) to exceed '
        'raiseHeight (${config.raiseHeight}) so the pocket leaves a floor.',
      );
    }

    for (int row = 0; row < mirroredBase.size; row++) {
      for (int col = 0; col < mirroredBase.size; col++) {
        final _Cell cell = mirroredBase.cellAt(row, col);
        final _Bounds bounds = cell.bounds;
        final double cellTop = cell.isDark ? cavityFloor : config.baseHeight;
        _addBaseCell(
          builder,
          mirroredBase,
          row,
          col,
          bounds,
          0,
          cellTop,
          config.baseHeight,
          cavityFloor,
        );
      }
    }

    final double effectiveGap = spacing > 0 ? spacing : config.moduleSize * 2;
    final double offsetX = matrix.totalSize + effectiveGap;

    Vector3 point(double x, double y, double z) {
      return vector(x + offsetX, y, z);
    }

    for (int row = 0; row < matrix.size; row++) {
      for (int col = 0; col < matrix.size; col++) {
        final _Cell cell = matrix.cellAt(row, col);
        if (!cell.isDark) {
          continue;
        }
        final _Bounds bounds = cell.bounds;
        _addTopFace(builder, bounds, config.raiseHeight, point: point);
        _addBottomFace(builder, bounds, 0, point: point);
        _addModuleSides(
          builder,
          matrix,
          row,
          col,
          bounds,
          0,
          config.raiseHeight,
          point: point,
        );
      }
    }

    return builder.toString();
  }

  _QrMatrix _createMatrix() {
    final QrCode code = config.toQrCode();
    final QrImage image = QrImage(code);
    final int moduleCount = image.moduleCount;
    final int totalCount = moduleCount + config.margin * 2;
    final double totalSize = totalCount * config.moduleSize;

    final List<List<bool>> values = List<List<bool>>.generate(totalCount, (int row) {
      return List<bool>.generate(totalCount, (int col) {
        final int qrRow = row - config.margin;
        final int qrCol = col - config.margin;
        if (qrRow < 0 || qrRow >= moduleCount || qrCol < 0 || qrCol >= moduleCount) {
          return false;
        }
        return image.isDark(qrRow, qrCol);
      });
    });

    return _QrMatrix(
      values: values,
      moduleSize: config.moduleSize,
      totalSize: totalSize,
    );
  }
}

void _addBaseShell(
  StlBuilder builder,
  double size,
  double height, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  final double x1 = 0;
  final double x2 = size;
  final double y1 = 0;
  final double y2 = size;
  final double z1 = 0;
  final double z2 = height;

  // bottom
  builder.addQuad(
    vector(0, 0, -1),
    point(x1, y2, z1),
    point(x2, y2, z1),
    point(x2, y1, z1),
    point(x1, y1, z1),
  );

  // west side (-x)
  builder.addQuad(
    vector(-1, 0, 0),
    point(x1, y1, z1),
    point(x1, y1, z2),
    point(x1, y2, z2),
    point(x1, y2, z1),
  );

  // east side (+x)
  builder.addQuad(
    vector(1, 0, 0),
    point(x2, y1, z1),
    point(x2, y2, z1),
    point(x2, y2, z2),
    point(x2, y1, z2),
  );

  // south side (-y)
  builder.addQuad(
    vector(0, -1, 0),
    point(x1, y1, z1),
    point(x2, y1, z1),
    point(x2, y1, z2),
    point(x1, y1, z2),
  );

  // north side (+y)
  builder.addQuad(
    vector(0, 1, 0),
    point(x1, y2, z1),
    point(x1, y2, z2),
    point(x2, y2, z2),
    point(x2, y2, z1),
  );
}

void _addFullBase(
  StlBuilder builder,
  double size,
  double height, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  _addBaseShell(builder, size, height, point: point);
  final _Bounds bounds = _Bounds(0, 0, size, size);
  _addTopFace(builder, bounds, height, point: point);
}

void _addRaisedTop(
  StlBuilder builder,
  _Bounds bounds,
  double z, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  _addTopFace(builder, bounds, z, point: point);
}

void _addTopFace(
  StlBuilder builder,
  _Bounds bounds,
  double z, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  builder.addQuad(
    vector(0, 0, 1),
    point(bounds.x1, bounds.y1, z),
    point(bounds.x2, bounds.y1, z),
    point(bounds.x2, bounds.y2, z),
    point(bounds.x1, bounds.y2, z),
  );
}

void _addBottomFace(
  StlBuilder builder,
  _Bounds bounds,
  double z, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  builder.addQuad(
    vector(0, 0, -1),
    point(bounds.x1, bounds.y2, z),
    point(bounds.x2, bounds.y2, z),
    point(bounds.x2, bounds.y1, z),
    point(bounds.x1, bounds.y1, z),
  );
}

void _addModuleSides(
  StlBuilder builder,
  _QrMatrix matrix,
  int row,
  int col,
  _Bounds bounds,
  double bottom,
  double top, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  if (top <= bottom) {
    return;
  }
  if (!matrix.isDark(row, col - 1)) {
    builder.addQuad(
      vector(-1, 0, 0),
      point(bounds.x1, bounds.y1, bottom),
      point(bounds.x1, bounds.y1, top),
      point(bounds.x1, bounds.y2, top),
      point(bounds.x1, bounds.y2, bottom),
    );
  }
  if (!matrix.isDark(row, col + 1)) {
    builder.addQuad(
      vector(1, 0, 0),
      point(bounds.x2, bounds.y1, bottom),
      point(bounds.x2, bounds.y2, bottom),
      point(bounds.x2, bounds.y2, top),
      point(bounds.x2, bounds.y1, top),
    );
  }
  if (!matrix.isDark(row - 1, col)) {
    builder.addQuad(
      vector(0, -1, 0),
      point(bounds.x1, bounds.y1, bottom),
      point(bounds.x2, bounds.y1, bottom),
      point(bounds.x2, bounds.y1, top),
      point(bounds.x1, bounds.y1, top),
    );
  }
  if (!matrix.isDark(row + 1, col)) {
    builder.addQuad(
      vector(0, 1, 0),
      point(bounds.x1, bounds.y2, bottom),
      point(bounds.x1, bounds.y2, top),
      point(bounds.x2, bounds.y2, top),
      point(bounds.x2, bounds.y2, bottom),
    );
  }
}

void _addBaseCell(
  StlBuilder builder,
  _QrMatrix matrix,
  int row,
  int col,
  _Bounds bounds,
  double bottom,
  double top,
  double baseHeight,
  double cavityFloor, {
  Vector3 Function(double x, double y, double z) point = vector,
}) {
  if (top <= bottom) {
    return;
  }

  _addTopFace(builder, bounds, top, point: point);
  _addBottomFace(builder, bounds, bottom, point: point);

  void addSide({
    required double neighborTop,
    required Vector3 Function(double z) originBuilder,
    required Vector3 Function(double z) farBuilder,
    required Vector3 normal,
  }) {
    if (top <= neighborTop) {
      return;
    }
    final double start = math.max(bottom, neighborTop);
    if (start >= top) {
      return;
    }
    builder.addQuad(
      normal,
      originBuilder(start),
      originBuilder(top),
      farBuilder(top),
      farBuilder(start),
    );
  }

  addSide(
    neighborTop: _baseCellTop(matrix, row, col - 1, baseHeight, cavityFloor),
    originBuilder: (double z) => point(bounds.x1, bounds.y1, z),
    farBuilder: (double z) => point(bounds.x1, bounds.y2, z),
    normal: vector(-1, 0, 0),
  );

  addSide(
    neighborTop: _baseCellTop(matrix, row, col + 1, baseHeight, cavityFloor),
    originBuilder: (double z) => point(bounds.x2, bounds.y2, z),
    farBuilder: (double z) => point(bounds.x2, bounds.y1, z),
    normal: vector(1, 0, 0),
  );

  addSide(
    neighborTop: _baseCellTop(matrix, row - 1, col, baseHeight, cavityFloor),
    originBuilder: (double z) => point(bounds.x1, bounds.y1, z),
    farBuilder: (double z) => point(bounds.x2, bounds.y1, z),
    normal: vector(0, -1, 0),
  );

  addSide(
    neighborTop: _baseCellTop(matrix, row + 1, col, baseHeight, cavityFloor),
    originBuilder: (double z) => point(bounds.x2, bounds.y2, z),
    farBuilder: (double z) => point(bounds.x1, bounds.y2, z),
    normal: vector(0, 1, 0),
  );
}

double _baseCellTop(
  _QrMatrix matrix,
  int row,
  int col,
  double baseHeight,
  double cavityFloor,
) {
  if (row < 0 || row >= matrix.size || col < 0 || col >= matrix.size) {
    return 0;
  }
  return matrix.isDark(row, col) ? cavityFloor : baseHeight;
}

class _QrMatrix {
  const _QrMatrix({
    required this.values,
    required this.moduleSize,
    required this.totalSize,
  });

  final List<List<bool>> values;
  final double moduleSize;
  final double totalSize;

  int get size => values.length;

  _Cell cellAt(int row, int col) {
    final double x1 = col * moduleSize;
    final double y1 = row * moduleSize;
    return _Cell(
      isDark: values[row][col],
      bounds: _Bounds(x1, y1, x1 + moduleSize, y1 + moduleSize),
    );
  }

  bool isDark(int row, int col) {
    if (row < 0 || row >= size || col < 0 || col >= size) {
      return false;
    }
    return values[row][col];
  }

  _QrMatrix mirroredRows() {
    final List<List<bool>> mirrored = values.reversed
        .map((List<bool> row) => List<bool>.from(row))
        .toList(growable: false);
    return _QrMatrix(
      values: mirrored,
      moduleSize: moduleSize,
      totalSize: totalSize,
    );
  }
}

class _Cell {
  const _Cell({required this.isDark, required this.bounds});

  final bool isDark;
  final _Bounds bounds;
}

class _Bounds {
  const _Bounds(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;
}
