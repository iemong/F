import Foundation

/// リポジトリルートの samples/ にある実機DNG（git管理外）。DNGKitTests と同じ規約
enum Fixtures {
    static let samplesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Fixtures.swift
        .deletingLastPathComponent() // DecodeKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // DecodeKit
        .deletingLastPathComponent() // Packages
        .appendingPathComponent("samples", isDirectory: true)

    static let hasSamples: Bool = FileManager.default
        .fileExists(atPath: samplesDirectory.path)

    static func url(_ name: String) -> URL {
        samplesDirectory.appendingPathComponent(name)
    }
}
