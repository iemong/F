import Foundation

public struct StackCandidate: Equatable, Sendable {
    public let url: URL
    public let capturedAt: Date?
    public let sequenceNumber: Int?
    public let perceptualHash: UInt64?

    public init(
        url: URL, capturedAt: Date?, sequenceNumber: Int?, perceptualHash: UInt64?
    ) {
        self.url = url
        self.capturedAt = capturedAt
        self.sequenceNumber = sequenceNumber
        self.perceptualHash = perceptualHash
    }
}

public struct PhotoStack: Identifiable, Equatable, Sendable {
    public let id: URL
    public let members: [URL]

    public init(id: URL, members: [URL]) {
        self.id = id
        self.members = members
    }

    public var representative: URL { members[0] }
}

public enum PhotoStackAnalyzer {
    /// 撮影時刻・連番が近く、画像ハッシュも大きく離れていない連続カットをまとめる。
    /// ハッシュが取得できない場合は時刻と連番だけで判定する。
    public static func makeStacks(
        candidates: [StackCandidate],
        timeWindow: TimeInterval = 3,
        maximumSequenceGap: Int = 2,
        maximumHashDistance: Int = 22
    ) -> [PhotoStack] {
        let ordered = candidates.sorted {
            switch ($0.capturedAt, $1.capturedAt) {
            case let (left?, right?) where left != right: left < right
            default: $0.url.path < $1.url.path
            }
        }
        guard !ordered.isEmpty else { return [] }

        var groups: [[StackCandidate]] = []
        var current = [ordered[0]]
        for candidate in ordered.dropFirst() {
            if let previous = current.last,
                belongsTogether(
                    previous, candidate,
                    timeWindow: timeWindow,
                    maximumSequenceGap: maximumSequenceGap,
                    maximumHashDistance: maximumHashDistance)
            {
                current.append(candidate)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [candidate]
            }
        }
        if current.count > 1 { groups.append(current) }

        return groups.map { group in
            let members = group.map(\.url)
            return PhotoStack(id: members[0].deletingPathExtension(), members: members)
        }
    }

    public static func sequenceNumber(in url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: #"\d+$"#, options: .regularExpression) else {
            return nil
        }
        return Int(stem[range])
    }

    public static func hammingDistance(_ left: UInt64, _ right: UInt64) -> Int {
        (left ^ right).nonzeroBitCount
    }

    /// グリッド表示用に、折りたたみ中は代表1枚、展開中はショットごとに1枚を返す。
    /// 同basenameのDNG/JPGは同じショットとして重複表示しない。
    public static func gridFiles(
        visibleFiles: [URL], stacks: [PhotoStack], expandedStackIDs: Set<URL>
    ) -> [URL] {
        let stackByBase = Dictionary(
            uniqueKeysWithValues: stacks.flatMap { stack in
                stack.members.map { ($0.deletingPathExtension(), stack) }
            })
        var emittedStacks = Set<URL>()
        var emittedShotBases = Set<URL>()
        var result: [URL] = []
        for url in visibleFiles {
            let base = url.deletingPathExtension()
            guard let stack = stackByBase[base] else {
                result.append(url)
                continue
            }
            if expandedStackIDs.contains(stack.id) {
                if emittedShotBases.insert(base).inserted { result.append(url) }
            } else if emittedStacks.insert(stack.id).inserted {
                result.append(url)
            }
        }
        return result
    }

    private static func belongsTogether(
        _ left: StackCandidate,
        _ right: StackCandidate,
        timeWindow: TimeInterval,
        maximumSequenceGap: Int,
        maximumHashDistance: Int
    ) -> Bool {
        guard let leftDate = left.capturedAt, let rightDate = right.capturedAt,
            abs(rightDate.timeIntervalSince(leftDate)) <= timeWindow,
            let leftSequence = left.sequenceNumber, let rightSequence = right.sequenceNumber,
            rightSequence > leftSequence,
            rightSequence - leftSequence <= maximumSequenceGap
        else { return false }

        if let leftHash = left.perceptualHash, let rightHash = right.perceptualHash {
            return hammingDistance(leftHash, rightHash) <= maximumHashDistance
        }
        return true
    }
}
