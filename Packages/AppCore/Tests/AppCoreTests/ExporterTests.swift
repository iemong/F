import Foundation
import Testing
import XMPKit

@testable import AppCore

@Suite("安全な書き出し")
struct ExporterTests {
    private func makeDirectories() throws -> (base: URL, source: URL, destination: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCoreExport-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let destination = base.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        return (base, source, destination)
    }

    @Test func 相対フォルダとXMPを維持してコピーする() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.base) }
        let nested = dirs.source.appendingPathComponent("100LEICA/day1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let image = nested.appendingPathComponent("L1000001.DNG")
        try Data("raw-data".utf8).write(to: image)
        try XMPSidecar.writeRating(4, forImageAt: image)

        let plan = Exporter.makePlan(
            sources: [image], sourceRoot: dirs.source,
            destination: dirs.destination, includeSidecars: true)
        let item = try #require(plan.items.first)
        #expect(
            item.targetImage
                == dirs.destination.appendingPathComponent("100LEICA/day1/L1000001.DNG"))
        #expect(plan.conflictCount == 0)

        let imageResult = Exporter.copyImage(item, verifyChecksum: true)
        let sidecarResult = Exporter.copySidecar(
            try #require(plan.sidecars.first), verifyChecksum: true)
        #expect(imageResult == .copied)
        #expect(sidecarResult == .copied)
        #expect(try Data(contentsOf: item.targetImage) == Data("raw-data".utf8))
        #expect(XMPSidecar.readRating(forImageAt: item.targetImage) == 4)
    }

    @Test func 既存ファイルを事前検出して上書きしない() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.base) }
        let image = dirs.source.appendingPathComponent("L1000002.DNG")
        let target = dirs.destination.appendingPathComponent("L1000002.DNG")
        try Data("new".utf8).write(to: image)
        try Data("existing".utf8).write(to: target)
        try XMPSidecar.writeRating(5, forImageAt: image)
        try XMPSidecar.writeRating(1, forImageAt: target)

        let plan = Exporter.makePlan(
            sources: [image], sourceRoot: dirs.source,
            destination: dirs.destination, includeSidecars: true)
        #expect(plan.imageConflictCount == 1)
        #expect(plan.sidecarConflictCount == 1)

        let imageResult = Exporter.copyImage(
            try #require(plan.items.first), verifyChecksum: false)
        #expect(imageResult == .skippedExisting)
        // アプリ側は画像をコピーできなかった場合、このXMPコピーを実行しない。
        #expect(plan.sidecars.count == 1)
        #expect(try Data(contentsOf: target) == Data("existing".utf8))
        #expect(XMPSidecar.readRating(forImageAt: target) == 1)
    }

    @Test func DNGとJPGの共有XMPは一度だけ計画する() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.base) }
        let dng = dirs.source.appendingPathComponent("L1000003.DNG")
        let jpg = dirs.source.appendingPathComponent("L1000003.JPG")
        try Data("dng".utf8).write(to: dng)
        try Data("jpg".utf8).write(to: jpg)
        try XMPSidecar.writeLabel("Red", forImageAt: dng)

        let plan = Exporter.makePlan(
            sources: [dng, jpg], sourceRoot: dirs.source,
            destination: dirs.destination, includeSidecars: true)
        #expect(plan.items.count == 2)
        #expect(plan.sidecars.count == 1)
        #expect(plan.sidecars.first?.relatedImageSources == [dng, jpg])
    }

    @Test func ルート外のファイルはbasenameへ安全にフォールバックする() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.base) }
        let outside = dirs.base.appendingPathComponent("outside.DNG")
        try Data().write(to: outside)

        let plan = Exporter.makePlan(
            sources: [outside], sourceRoot: dirs.source,
            destination: dirs.destination, includeSidecars: false)
        #expect(
            plan.items.first?.targetImage
                == dirs.destination.appendingPathComponent("outside.DNG"))
    }

    @Test func 出力先ディレクトリを作れない場合は失敗を返す() throws {
        let dirs = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.base) }
        let nested = dirs.source.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let image = nested.appendingPathComponent("L1000004.DNG")
        try Data("raw".utf8).write(to: image)
        try Data("not-a-directory".utf8).write(
            to: dirs.destination.appendingPathComponent("blocked"))

        let plan = Exporter.makePlan(
            sources: [image], sourceRoot: dirs.source,
            destination: dirs.destination, includeSidecars: false)
        let result = Exporter.copyImage(
            try #require(plan.items.first), verifyChecksum: false)
        #expect(result == .failed)
    }

    @Test func 集計で画像とXMPの失敗を区別する() {
        var result = ExportResult()
        result.recordImage(.copied)
        result.recordSidecar(.verificationFailed)
        result.recordImage(.failed)
        result.recordSidecar(.notAttempted)

        #expect(result.imagesCopied == 1)
        #expect(result.imagesFailed == 1)
        #expect(result.sidecarsVerificationFailed == 1)
        #expect(result.sidecarsNotAttempted == 1)
    }
}
