Pod::Spec.new do |s|
  s.name             = 'rpc_dart_wasm'
  s.version          = '0.1.0'
  s.summary          = 'WASM runtime bridge transport for rpc_dart'
  s.homepage         = 'https://github.com/nogipx/rpc_dart'
  s.license          = { :type => 'MIT' }
  s.author           = { 'rpc_dart' => 'nogipx@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
end
