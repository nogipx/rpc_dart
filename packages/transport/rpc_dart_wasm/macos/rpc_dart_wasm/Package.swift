// swift-tools-version: 5.9
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "rpc_dart_wasm",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "rpc-dart-wasm", targets: ["rpc_dart_wasm"])
    ],
    // No FlutterFramework package: Flutter 3.38, the SDK this repository pins,
    // does not make one, and the app target links FlutterMacOS either way.
    dependencies: [],
    targets: [
        .target(
            name: "rpc_dart_wasm",
            dependencies: [],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
