import AppCore
import Foundation

struct FileFingerprint: Codable, Equatable, Sendable {
    let byteCount: Int
    let modifiedAt: TimeInterval

    static func read(from url: URL) -> FileFingerprint? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ]),
            let byteCount = values.fileSize,
            let modified = values.contentModificationDate
        else { return nil }
        return FileFingerprint(
            byteCount: byteCount, modifiedAt: modified.timeIntervalSince1970)
    }
}

struct AssistCacheEntry: Codable, Equatable, Sendable {
    let fingerprint: FileFingerprint
    var capturedAt: TimeInterval?
    var sequenceNumber: Int?
    var perceptualHash: UInt64?
    var quality: QualityMetrics?
}

/// 選別アシスト専用キャッシュ。解析結果だけをCaches配下へ保存し、DNG/XMPは触らない。
actor SelectionAssistCache {
    private let fileURL: URL
    private var entries: [String: AssistCacheEntry]

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base
            .appendingPathComponent("jp.iemong.F", isDirectory: true)
            .appendingPathComponent("selection-assist-v1.json")
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(
                [String: AssistCacheEntry].self, from: data)
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func entry(for url: URL, fingerprint: FileFingerprint) -> AssistCacheEntry? {
        guard let cached = entries[url.standardizedFileURL.path],
            cached.fingerprint == fingerprint
        else { return nil }
        return cached
    }

    func update(_ updates: [URL: AssistCacheEntry]) {
        guard !updates.isEmpty else { return }
        for (url, entry) in updates {
            let key = url.standardizedFileURL.path
            if let existing = entries[key], existing.fingerprint == entry.fingerprint {
                entries[key] = AssistCacheEntry(
                    fingerprint: entry.fingerprint,
                    capturedAt: entry.capturedAt ?? existing.capturedAt,
                    sequenceNumber: entry.sequenceNumber ?? existing.sequenceNumber,
                    perceptualHash: entry.perceptualHash ?? existing.perceptualHash,
                    quality: entry.quality ?? existing.quality)
            } else {
                entries[key] = entry
            }
        }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // キャッシュ失敗は選別操作を妨げない。次回起動時に再解析すればよい。
        }
    }
}

enum ExifDateParser {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let components = text.split(whereSeparator: { $0 == ":" || $0 == " " })
        guard components.count == 6,
            let year = Int(components[0]), let month = Int(components[1]),
            let day = Int(components[2]), let hour = Int(components[3]),
            let minute = Int(components[4]), let second = Int(components[5])
        else { return nil }
        var values = DateComponents()
        values.calendar = Calendar(identifier: .gregorian)
        values.timeZone = .current
        values.year = year
        values.month = month
        values.day = day
        values.hour = hour
        values.minute = minute
        values.second = second
        return values.date
    }
}
