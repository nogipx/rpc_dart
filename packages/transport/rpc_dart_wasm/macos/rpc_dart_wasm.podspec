Pod::Spec.new do |s|
  s.name             = 'rpc_dart_wasm'
  s.version          = '0.2.1'
  s.summary          = 'WASM and JS guest bridge transport for rpc_dart'
  s.homepage         = 'https://github.com/nogipx/rpc_dart'
  s.license          = { :type => 'MIT' }
  s.author           = { 'rpc_dart' => 'nogipx@gmail.com' }
  s.source           = { :path => '.' }
  # The sources live where Swift Package Manager wants them; CocoaPods reads
  # the same files, so the two builds cannot drift.
  s.source_files     = 'rpc_dart_wasm/Sources/rpc_dart_wasm/**/*.swift'
  s.resource_bundles = {
    'rpc_dart_wasm_privacy' => ['rpc_dart_wasm/Sources/rpc_dart_wasm/PrivacyInfo.xcprivacy']
  }
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'
end
