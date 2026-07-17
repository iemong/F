import Foundation
import XMPKit

extension URL {
    /// 対応するJPEG拡張子か。列挙・表示・メタデータ処理で共用する。
    public var isJPEGFile: Bool {
        let ext = pathExtension.uppercased()
        return ext == "JPG" || ext == "JPEG"
    }
}

public enum FileTypeMode: String, CaseIterable, Sendable {
    case dng
    case jpg
    case both

    public func matches(_ url: URL) -> Bool {
        switch self {
        case .dng: !url.isJPEGFile
        case .jpg: url.isJPEGFile
        case .both: true
        }
    }
}

public enum EvaluationFilter: String, CaseIterable, Sendable {
    case all
    case unrated
    case rated
}

public struct FilterState: Equatable, Sendable {
    public var minRating: Int
    public var hideRejected: Bool
    public var label: String?
    public var keyword: String?
    public var evaluation: EvaluationFilter

    public init(
        minRating: Int = 0,
        hideRejected: Bool = false,
        label: String? = nil,
        keyword: String? = nil,
        evaluation: EvaluationFilter = .all
    ) {
        self.minRating = minRating
        self.hideRejected = hideRejected
        self.label = label
        self.keyword = keyword
        self.evaluation = evaluation
    }

    public var isActive: Bool {
        minRating > 0 || hideRejected || label != nil || keyword != nil || evaluation != .all
    }
}

public struct SelectionProgress: Equatable, Sendable {
    public let evaluated: Int
    public let total: Int

    public init(evaluated: Int, total: Int) {
        self.evaluated = evaluated
        self.total = total
    }
}

public enum LibrarySelection {
    public static func typedFiles(_ files: [URL], mode: FileTypeMode) -> [URL] {
        mode == .both ? files : files.filter { mode.matches($0) }
    }

    public static func visibleFiles(
        _ files: [URL],
        mode: FileTypeMode,
        filter: FilterState,
        ratings: [URL: Int],
        labels: [URL: String],
        keywords: [URL: [String]]
    ) -> [URL] {
        let typed = typedFiles(files, mode: mode)
        guard filter.isActive else { return typed }
        return typed.filter { url in
            let rating = ratings[url] ?? 0
            if filter.evaluation == .unrated, rating != 0 { return false }
            if filter.evaluation == .rated, rating == 0 { return false }
            if filter.hideRejected, rating == -1 { return false }
            if filter.minRating > 0, rating < filter.minRating { return false }
            if let wanted = filter.label, labels[url] != wanted { return false }
            if let wanted = filter.keyword,
                !(keywords[url]?.contains(wanted) ?? false)
            {
                return false
            }
            return true
        }
    }

    public static func pairedURLs(of url: URL, in files: [URL]) -> [URL] {
        let base = url.deletingPathExtension()
        return files.filter { $0.deletingPathExtension() == base }
    }

    /// DNG/JPGペアを同じbasenameの1ショットとして数えた選別進捗。
    public static func selectionProgress(
        _ files: [URL], mode: FileTypeMode, ratings: [URL: Int]
    ) -> SelectionProgress {
        let shots = Dictionary(grouping: typedFiles(files, mode: mode)) {
            $0.deletingPathExtension()
        }
        let evaluated = shots.values.count { members in
            members.contains { (ratings[$0] ?? 0) != 0 }
        }
        return SelectionProgress(evaluated: evaluated, total: shots.count)
    }

    /// 表示条件変更後の選択位置。元ファイル、同basenameのペア、現在位置の順で維持する。
    public static func reselectedIndex(
        previous selected: URL?, currentIndex: Int, visibleFiles: [URL]
    ) -> Int {
        guard !visibleFiles.isEmpty else { return 0 }
        if let selected {
            if let index = visibleFiles.firstIndex(of: selected) { return index }
            let base = selected.deletingPathExtension()
            if let index = visibleFiles.firstIndex(where: {
                $0.deletingPathExtension() == base
            }) {
                return index
            }
        }
        return min(max(0, currentIndex), visibleFiles.count - 1)
    }
}

public struct TrashPlan: Sendable, Equatable {
    public let imageURLs: [URL]
    public let sidecarURLs: Set<URL>

    public init(imageURLs: [URL], sidecarURLs: Set<URL>) {
        self.imageURLs = imageURLs
        self.sidecarURLs = sidecarURLs
    }
}

public enum LibraryOperations {
    /// ペア相手が残る場合は共有XMPを対象から外す。
    public static func trashPlan(rejectedURLs: [URL], allFiles: [URL]) -> TrashPlan {
        let rejected = Set(rejectedURLs)
        let pairs = Dictionary(grouping: allFiles) { $0.deletingPathExtension() }
        let sidecars = Set(
            rejectedURLs.compactMap { url -> URL? in
                let members = pairs[url.deletingPathExtension()] ?? [url]
                guard members.allSatisfy({ rejected.contains($0) }) else { return nil }
                return XMPSidecar.url(for: url)
            })
        return TrashPlan(imageURLs: rejectedURLs, sidecarURLs: sidecars)
    }
}

public enum ImageDiscovery {
    /// DNG/JPGを再帰列挙する。隠しファイルとパッケージ内部は対象外。
    public static func findImages(in root: URL, limit: Int = 10_000) -> [URL] {
        guard limit > 0 else { return [] }
        let wanted: Set<String> = ["DNG", "JPG", "JPEG"]
        var result: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let item = enumerator?.nextObject() as? URL {
            guard wanted.contains(item.pathExtension.uppercased()) else { continue }
            guard
                (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            result.append(item)
            if result.count >= limit { break }
        }
        return result.sorted { $0.path < $1.path }
    }
}
