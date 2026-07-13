import Foundation

/// アプリ内からのXMP更新を直列化し、遅れて到着した古い更新を無視する。
///
/// `Data.write(.atomic)` が保証するのはファイル置換の原子性だけで、複数の
/// read-modify-write間の順序までは保証しない。このactorを1つ共有することで、
/// レート・ラベル・キーワードを互いに失わずに更新する。
public actor XMPWriteCoordinator {
    private struct Revisions {
        var rating: UInt64 = 0
        var label: UInt64 = 0
        var keywords: UInt64 = 0
    }

    private var revisionsBySidecar: [URL: Revisions] = [:]

    public init() {}

    /// 戻り値は書き込みを適用した場合にtrue。より新しい更新が到着済みならfalse。
    @discardableResult
    public func writeRating(
        _ rating: Int,
        forImageAt imageURL: URL,
        revision: UInt64,
        createSidecarIfMissing: Bool = true
    ) throws -> Bool {
        let key = sidecarKey(for: imageURL)
        var revisions = revisionsBySidecar[key] ?? Revisions()
        guard revision > revisions.rating else { return false }
        revisions.rating = revision
        revisionsBySidecar[key] = revisions
        if !createSidecarIfMissing,
            !FileManager.default.fileExists(atPath: key.path)
        {
            return true
        }
        try XMPSidecar.writeRating(rating, forImageAt: imageURL)
        return true
    }

    @discardableResult
    public func writeLabel(
        _ label: String?, forImageAt imageURL: URL, revision: UInt64
    ) throws -> Bool {
        let key = sidecarKey(for: imageURL)
        var revisions = revisionsBySidecar[key] ?? Revisions()
        guard revision > revisions.label else { return false }
        revisions.label = revision
        revisionsBySidecar[key] = revisions
        try XMPSidecar.writeLabel(label, forImageAt: imageURL)
        return true
    }

    @discardableResult
    public func writeKeywords(
        _ keywords: [String], forImageAt imageURL: URL, revision: UInt64
    ) throws -> Bool {
        let key = sidecarKey(for: imageURL)
        var revisions = revisionsBySidecar[key] ?? Revisions()
        guard revision > revisions.keywords else { return false }
        revisions.keywords = revision
        revisionsBySidecar[key] = revisions
        try XMPSidecar.writeKeywords(keywords, forImageAt: imageURL)
        return true
    }

    private func sidecarKey(for imageURL: URL) -> URL {
        XMPSidecar.url(for: imageURL).standardizedFileURL
    }
}
