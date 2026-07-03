import Foundation

/// リポジトリルートの samples/ にある実機DNGをフィクスチャとして参照する。
/// samples/ は容量の都合で git 管理外のため、存在しない環境では
/// フィクスチャ依存のテストは .enabled(if:) でスキップされる。
enum Fixtures {
    static let samplesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Fixtures.swift
        .deletingLastPathComponent() // DNGKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // DNGKit
        .deletingLastPathComponent() // Packages
        .appendingPathComponent("samples", isDirectory: true)

    static let hasSamples: Bool = FileManager.default
        .fileExists(atPath: samplesDirectory.path)

    static func url(_ name: String) -> URL {
        samplesDirectory.appendingPathComponent(name)
    }

    static func allDNGs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: samplesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.uppercased() == "DNG" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
