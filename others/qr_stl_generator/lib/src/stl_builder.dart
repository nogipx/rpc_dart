
class StlFacet {
  const StlFacet({
    required this.normal,
    required this.a,
    required this.b,
    required this.c,
  });

  final Vector3 normal;
  final Vector3 a;
  final Vector3 b;
  final Vector3 c;

  @override
  String toString() {
    return '  facet normal ${normal.format()}'
        '\n    outer loop'
        '\n      vertex ${a.format()}'
        '\n      vertex ${b.format()}'
        '\n      vertex ${c.format()}'
        '\n    endloop'
        '\n  endfacet\n';
  }
}

class StlBuilder {
  StlBuilder({required this.name});

  final String name;
  final List<StlFacet> _facets = <StlFacet>[];

  void addFacet(Vector3 normal, Vector3 a, Vector3 b, Vector3 c) {
    _facets.add(StlFacet(normal: normal, a: a, b: b, c: c));
  }

  void addQuad(Vector3 normal, Vector3 a, Vector3 b, Vector3 c, Vector3 d) {
    addFacet(normal, a, b, c);
    addFacet(normal, a, c, d);
  }

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('solid ${name}\n');
    for (final StlFacet facet in _facets) {
      buffer.write(facet.toString());
    }
    buffer.write('endsolid ${name}\n');
    return buffer.toString();
  }
}

class Vector3 {
  const Vector3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  String format() {
    return '${_formatDouble(x)} ${_formatDouble(y)} ${_formatDouble(z)}';
  }
}

String _formatDouble(double value) {
  if (value == 0) {
    return '0';
  }
  final double rounded = (value.abs() < 1e-9) ? 0 : value;
  final String text = rounded.toStringAsFixed(6);
  if (!text.contains('.')) {
    return text;
  }
  final String trimmed = text.replaceFirst(RegExp(r'0+$'), '');
  if (trimmed.endsWith('.')) {
    return trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

Vector3 vector(double x, double y, double z) => Vector3(x, y, z);
