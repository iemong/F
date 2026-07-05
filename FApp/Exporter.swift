import Foundation
import XMPKit

/// エクスポート対象の絞り込み。「グループ」（ラベル/キーワード）単位の書き出しにも使う
enum ExportScope: Hashable, Sendable {
    /// 現在の表示対象（フィルター適用後）
    case visible
    /// レート★n以上
    case minRating(Int)
    /// カラーラベル一致
    case label(String)
    /// キーワードを含む
    case keyword(String)
}

struct ExportResult: Sendable, Equatable {
    var copied = 0
    /// 同名ファイルが書き出し先に既にあった（上書きしない）
    var skipped = 0
    var failed = 0
}

/// 実行中エクスポートの進捗（シートに表示）
struct ExportProgress: Equatable {
    var completed = 0
    var total = 0
}

enum ExportCopyOutcome: Sendable {
    case copied
    case skippedExisting
    case failed
}

enum Exporter {
    /// DNG 1件（+存在すればXMPサイドカー）を destination へコピーする。
    /// 同名ファイルが既にあれば上書きせずスキップ（既存データの保護を優先）
    static func copyItem(
        at url: URL, into destination: URL, includeSidecar: Bool
    ) -> ExportCopyOutcome {
        let fm = FileManager.default
        let target = destination.appendingPathComponent(url.lastPathComponent)
        let outcome: ExportCopyOutcome
        if fm.fileExists(atPath: target.path) {
            outcome = .skippedExisting
        } else {
            do {
                try fm.copyItem(at: url, to: target)
                outcome = .copied
            } catch {
                return .failed
            }
        }
        if includeSidecar {
            let sidecar = XMPSidecar.url(for: url)
            let sidecarTarget = destination.appendingPathComponent(sidecar.lastPathComponent)
            if fm.fileExists(atPath: sidecar.path),
                !fm.fileExists(atPath: sidecarTarget.path)
            {
                try? fm.copyItem(at: sidecar, to: sidecarTarget)
            }
        }
        return outcome
    }
}
