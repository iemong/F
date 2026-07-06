import Foundation

/// バイトコスト上限つきLRUキャッシュ + 先読み。
/// - 同一キーの同時要求はインフライトのロードに合流する（ローダーは1回だけ走る）
/// - prefetch はバックグラウンド優先度でロードし、cancelPrefetches で
///   不要になったものをまとめてキャンセルできる
/// - キャンセル済みプリフェッチに value(for:) が当たった場合は自動で再ロードする
public actor LRUByteCache<Key: Hashable & Sendable, Value: Sendable> {
    public struct Stats: Sendable {
        public var hits = 0
        public var misses = 0
        public var evictions = 0
        public var totalBytes = 0
    }

    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    private let byteLimit: Int
    private let costOf: @Sendable (Value) -> Int

    private var entries: [Key: Entry] = [:]
    private var inflight: [Key: Task<Value, any Error>] = [:]
    private var prefetching: Set<Key> = []
    private var tick: UInt64 = 0
    private var stats = Stats()

    public init(byteLimit: Int, costOf: @escaping @Sendable (Value) -> Int) {
        self.byteLimit = byteLimit
        self.costOf = costOf
    }

    public func currentStats() -> Stats {
        stats
    }

    /// 値が既にあればそのまま返す（ローダー起動・統計・LRU使用時刻の更新は一切しない）。
    /// インフライトのロードは「まだ無い」扱いで nil。
    /// ミス時だけ速報表示を出す、といった分岐の判定に使う
    public func peek(_ key: Key) -> Value? {
        entries[key]?.value
    }

    /// キャッシュから取得。なければローダーで取得してキャッシュする
    public func value(
        for key: Key,
        loader: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        tick += 1
        if var entry = entries[key] {
            entry.lastUse = tick
            entries[key] = entry
            stats.hits += 1
            return entry.value
        }
        stats.misses += 1

        if let task = inflight[key] {
            // プリフェッチ中なら本要求に昇格（以後のキャンセル対象から外す）
            prefetching.remove(key)
            do {
                return try await task.value
            } catch is CancellationError {
                // キャンセル済みプリフェッチに当たった → 作り直す
            }
        }

        let task = startLoad(key: key, prefetch: false, loader: loader)
        return try await task.value
    }

    /// バックグラウンドで先読み。完了を観測できるよう Task を返す
    /// （キャッシュ済みなら即座に解決、ロード中なら既存タスクに合流）
    @discardableResult
    public func prefetch(
        key: Key,
        loader: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, any Error> {
        tick += 1
        if var entry = entries[key] {
            // 近傍として触れたことにして追い出されにくくする
            entry.lastUse = tick
            entries[key] = entry
            let value = entry.value
            return Task { value }
        }
        if let existing = inflight[key] {
            return existing
        }
        return startLoad(key: key, prefetch: true, loader: loader)
    }

    /// keeping に含まれないプリフェッチをキャンセルする。
    /// 本要求（value経由）のロードはキャンセルされない
    public func cancelPrefetches(keeping keys: Set<Key>) {
        for key in prefetching where !keys.contains(key) {
            inflight[key]?.cancel()
        }
    }

    // MARK: - 内部

    private func startLoad(
        key: Key, prefetch: Bool,
        loader: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, any Error> {
        let task = Task(priority: prefetch ? .utility : .userInitiated) {
            try Task.checkCancellation()
            return try await loader()
        }
        inflight[key] = task
        if prefetch { prefetching.insert(key) }
        Task { await self.finalizeLoad(key: key, task: task) }
        return task
    }

    private func finalizeLoad(key: Key, task: Task<Value, any Error>) async {
        let value = try? await task.value
        if inflight[key] == task {
            inflight[key] = nil
            prefetching.remove(key)
        }
        if let value {
            insert(key: key, value: value)
        }
    }

    private func insert(key: Key, value: Value) {
        guard entries[key] == nil else { return }
        tick += 1
        let cost = costOf(value)
        entries[key] = Entry(value: value, cost: cost, lastUse: tick)
        stats.totalBytes += cost

        while stats.totalBytes > byteLimit, entries.count > 1 {
            guard
                let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }),
                victim.key != key
            else { break }
            entries.removeValue(forKey: victim.key)
            stats.totalBytes -= victim.value.cost
            stats.evictions += 1
        }
    }
}
