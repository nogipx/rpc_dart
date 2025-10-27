import '../../utils/base64_utils.dart';

class ProductConfigAndroid {
  final String packageName;
  final String sha1;
  final String sha256;

  const ProductConfigAndroid({
    required this.packageName,
    required this.sha256,
    this.sha1 = '',
  });

  List<String> get keystoreFingerprints => [
    if (sha1.isNotEmpty) sha1,
    if (sha256.isNotEmpty) sha256,
  ];

  String get origin {
    String hexString = sha256.replaceAll(':', '');
    List<int> bytes = [];
    for (int i = 0; i < hexString.length; i += 2) {
      bytes.add(int.parse(hexString.substring(i, i + 2), radix: 16));
    }
    final base64String = WebAuthnSafeBase64.encode(bytes);

    return 'android:apk-key-hash:$base64String';
  }
}
