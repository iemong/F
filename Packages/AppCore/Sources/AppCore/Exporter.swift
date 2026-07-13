import CryptoKit
import Foundation
import XMPKit

public enum ExportScope: Hashable, Sendable {
    case visible
    case minRating(Int)
    case label(String)
    case keyword(String)
}

public struct ExportProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int

    public init(completed: Int = 0, total: Int = 0) {
        self.completed = completed
        self.total = total
    }
}

public enum ExportAssetOutcome: Sendable, Equatable {
    case copied
    case skippedExisting
    case failed
    case verificationFailed
    case notAttempted
}

public struct ExportResult: Sendable, Equatable {
    public var imagesCopied = 0
    public var imagesSkipped = 0
    public var imagesFailed = 0
    public var imagesVerificationFailed = 0
    public var sidecarsCopied = 0
    public var sidecarsSkipped = 0
    public var sidecarsFailed = 0
    public var sidecarsVerificationFailed = 0
    public var sidecarsNotAttempted = 0

    public init() {}

    public mutating func recordImage(_ outcome: ExportAssetOutcome) {
        switch outcome {
        case .copied: imagesCopied += 1
        case .skippedExisting: imagesSkipped += 1
        case .failed, .notAttempted: imagesFailed += 1
        case .verificationFailed: imagesVerificationFailed += 1
        }
    }

    public mutating func recordSidecar(_ outcome: ExportAssetOutcome) {
        switch outcome {
        case .copied: sidecarsCopied += 1
        case .skippedExisting: sidecarsSkipped += 1
        case .failed: sidecarsFailed += 1
        case .verificationFailed: sidecarsVerificationFailed += 1
        case .notAttempted: sidecarsNotAttempted += 1
        }
    }
}

public struct ExportPlanItem: Sendable, Equatable {
    public let sourceImage: URL
    public let targetImage: URL
    public let imageConflict: Bool
}

public struct ExportSidecarPlanItem: Sendable, Equatable {
    public let sourceSidecar: URL
    public let targetSidecar: URL
    /// 共有XMPに対応するDNG/JPG。この実行で1枚以上コピーできた場合だけXMPをコピーする。
    public let relatedImageSources: [URL]
    public let conflict: Bool
}

public struct ExportPlan: Sendable, Equatable {
    public let items: [ExportPlanItem]
    public let sidecars: [ExportSidecarPlanItem]

    public init(items: [ExportPlanItem], sidecars: [ExportSidecarPlanItem]) {
        self.items = items
        self.sidecars = sidecars
    }

    public var imageConflictCount: Int { items.count(where: \.imageConflict) }
    public var sidecarConflictCount: Int { sidecars.count(where: \.conflict) }
    public var conflictCount: Int { imageConflictCount + sidecarConflictCount }
}

public enum Exporter {
    /// コピー対象を事前計画する。再帰フォルダの相対構造を出力先でも維持する。
    public static func makePlan(
        sources: [URL],
        sourceRoot: URL,
        destination: URL,
        includeSidecars: Bool
    ) -> ExportPlan {
        let fm = FileManager.default
        let items = sources.map { source in
            let target = targetURL(
                for: source, sourceRoot: sourceRoot, destination: destination)
            return ExportPlanItem(
                sourceImage: source,
                targetImage: target,
                imageConflict: fm.fileExists(atPath: target.path))
        }
        guard includeSidecars else { return ExportPlan(items: items, sidecars: []) }

        let grouped = Dictionary(
            grouping: sources.filter {
                fm.fileExists(atPath: XMPSidecar.url(for: $0).path)
            }
        ) {
            XMPSidecar.url(for: $0).standardizedFileURL
        }
        let sidecars = grouped.map { sourceSidecar, relatedSources in
            let orderedSources = relatedSources.sorted { $0.path < $1.path }
            let firstSource = orderedSources[0]
            let firstTarget = targetURL(
                for: firstSource, sourceRoot: sourceRoot, destination: destination)
            let targetSidecar = firstTarget.deletingPathExtension()
                .appendingPathExtension("xmp")
            return ExportSidecarPlanItem(
                sourceSidecar: sourceSidecar,
                targetSidecar: targetSidecar,
                relatedImageSources: orderedSources,
                conflict: fm.fileExists(atPath: targetSidecar.path))
        }.sorted { $0.sourceSidecar.path < $1.sourceSidecar.path }
        return ExportPlan(items: items, sidecars: sidecars)
    }

    public static func copyImage(
        _ item: ExportPlanItem, verifyChecksum: Bool
    ) -> ExportAssetOutcome {
        copyAsset(
            from: item.sourceImage, to: item.targetImage,
            verifyChecksum: verifyChecksum)
    }

    public static func copySidecar(
        _ item: ExportSidecarPlanItem, verifyChecksum: Bool
    ) -> ExportAssetOutcome {
        copyAsset(
            from: item.sourceSidecar, to: item.targetSidecar,
            verifyChecksum: verifyChecksum)
    }

    static func targetURL(
        for source: URL, sourceRoot: URL, destination: URL
    ) -> URL {
        let sourceComponents = source.standardizedFileURL.pathComponents
        let rootComponents = sourceRoot.standardizedFileURL.pathComponents
        guard sourceComponents.starts(with: rootComponents),
            sourceComponents.count > rootComponents.count
        else {
            return destination.appendingPathComponent(source.lastPathComponent)
        }
        return sourceComponents.dropFirst(rootComponents.count).reduce(destination) {
            $0.appendingPathComponent($1)
        }
    }

    private static func copyAsset(
        from source: URL, to target: URL, verifyChecksum: Bool
    ) -> ExportAssetOutcome {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return .skippedExisting }
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        } catch {
            return .failed
        }
        guard verifyChecksum else { return .copied }
        do {
            return try sha256(of: source) == sha256(of: target)
                ? .copied : .verificationFailed
        } catch {
            return .verificationFailed
        }
    }

    private static func sha256(of url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
