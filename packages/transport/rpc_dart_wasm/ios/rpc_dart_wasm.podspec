Pod::Spec.new do |s|
  s.name             = 'rpc_dart_wasm'
  s.version          = '0.2.0'
  s.summary          = 'WASM runtime bridge transport for rpc_dart'
  s.homepage         = 'https://github.com/nogipx/rpc_dart'
  s.license          = { :type => 'MIT' }
  s.author           = { 'rpc_dart' => 'nogipx@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  # Apple requires a privacy manifest from bundled SDKs. The file existed in
  # this package but was NOT declared here, so it was never packaged: measured
  # on a built Runner.app, PrivacyInfo.xcprivacy was present in
  # Flutter.framework and absent from rpc_dart_wasm.framework.
  s.resource_bundles = {
    'rpc_dart_wasm_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
end
