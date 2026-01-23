import 'dart:convert';

import 'product_config_android.dart';

class ProductConfig {
  /// Список origin для веб-платформы
  final Uri webOrigin;

  /// Android package name (applicationId)
  final ProductConfigAndroid androidAppInfo;

  /// iOS Bundle ID
  final String iosBundleId;

  ProductConfig({
    required this.webOrigin,
    required this.androidAppInfo,
    required this.iosBundleId,
  });

  /// Возвращает данные для .well-known/assetlinks.json (Android)
  List<Map<String, dynamic>> getAndroidAssetLinks() {
    return [
      {
        'relation': [
          'delegate_permission/common.handle_all_urls',
          'delegate_permission/common.get_login_creds',
        ],
        'target': {
          'namespace': 'android_app',
          'package_name': androidAppInfo.packageName,
          'sha256_cert_fingerprints': androidAppInfo.keystoreFingerprints,
        },
      },
    ];
  }

  /// Возвращает данные для .well-known/apple-app-site-association (iOS)
  Map<String, dynamic> getAppleAppSiteAssociation() {
    return {
      'applinks': {
        'apps': [],
        'details': [
          {
            'appID': iosBundleId,
            'paths': ['*'],
          },
        ],
      },
      'webcredentials': {
        'apps': [iosBundleId],
      },
      'appclips': {'apps': []},
    };
  }

  /// Возвращает JSON строку для .well-known/assetlinks.json
  String getAndroidAssetLinksJson() {
    return jsonEncode(getAndroidAssetLinks());
  }

  /// Возвращает JSON строку для .well-known/apple-app-site-association
  String getAppleAppSiteAssociationJson() {
    return jsonEncode(getAppleAppSiteAssociation());
  }
}
