
import 'package:qr/qr.dart';

enum TwoColorMode { singleSwap, dualStl }

class QrStlConfig {
  const QrStlConfig({
    required this.data,
    this.moduleSize = 1.0,
    this.baseHeight = 0.4,
    this.raiseHeight = 0.4,
    this.margin = 4,
    this.errorCorrectLevel = QrErrorCorrectLevel.M,
    this.inlay = false,
  })  : assert(moduleSize > 0, 'moduleSize must be greater than zero'),
        assert(baseHeight > 0, 'baseHeight must be greater than zero'),
        assert(raiseHeight >= 0, 'raiseHeight cannot be negative'),
        assert(!inlay || raiseHeight > 0,
            'raiseHeight must be positive when inlay mode is enabled'),
        assert(!inlay || baseHeight > raiseHeight,
            'baseHeight must exceed raiseHeight in inlay mode'),
        assert(margin >= 0, 'margin cannot be negative');

  final String data;
  final double moduleSize;
  final double baseHeight;
  final double raiseHeight;
  final int margin;
  final int errorCorrectLevel;
  final bool inlay;

  QrCode toQrCode() {
    return QrCode.fromData(
      data: data,
      errorCorrectLevel: errorCorrectLevel,
    );
  }
}

class DualStlResult {
  const DualStlResult({
    required this.base,
    required this.modules,
  });

  final String base;
  final String modules;
}
