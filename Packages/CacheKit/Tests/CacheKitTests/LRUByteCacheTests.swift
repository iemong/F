import Foundation
import Testing
@testable import CacheKit

/// ローダー呼び出し回数の記録用
actor LoadCounter {
    private(set) var counts: [String: Int] = [:]
    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }
    func count(_ key: String) -> Int {
        counts[key] ?? 0
    }
}

@Suite("LRUByteCache")
struct LRUByteCacheTests {
    @Test func ヒットとミスの基本動作() async throws {
        let cache = LRUByteCache<String, Int>(byteLimit: 1000) { _ in 100 }
        let counter = LoadCounter()

        let first = try await cache.value(for: "a") {
            await counter.increment("a")
            return 1
        }
        #expect(first == 1)

        // 2回目はキャッシュヒット（ローダーは呼ばれない）
        let second = try await cache.value(for: "a") {
            await counter.increment("a")
            return 2
        }
        #expect(second == 1)
        #expect(await counter.count("a") == 1)

        let stats = await cache.currentStats()
        #expect(stats.hits == 1)
        #expect(stats.misses == 1)
        #expect(stats.totalBytes == 100)
    }

    @Test func バイト上限でLRU追い出し() async throws {
        let cache = LRUByteCache<String, Int>(byteLimit: 300) { _ in 100 }
        _ = try await cache.value(for: "a") { 1 }
        _ = try await cache.value(for: "b") { 2 }
        _ = try await cache.value(for: "c") { 3 }
        // a に触って最古を b にする
        _ = try await cache.value(for: "a") { -1 }
        // d 追加 → b が追い出される
        _ = try await cache.value(for: "d") { 4 }

        let counter = LoadCounter()
        _ = try await cache.value(for: "b") {
            await counter.increment("b")
            return 20
        }
        #expect(await counter.count("b") == 1, "bは追い出されて再ロードされるはず")

        _ = try await cache.value(for: "a") {
            await counter.increment("a")
            return -2
        }
        #expect(await counter.count("a") == 0, "aは残っているはず")
    }

    @Test func 同一キーの同時要求はローダー1回に集約() async throws {
        let cache = LRUByteCache<String, Int>(byteLimit: 1000) { _ in 1 }
        let counter = LoadCounter()

        async let first = cache.value(for: "slow") {
            await counter.increment("slow")
            try await Task.sleep(for: .milliseconds(50))
            return 42
        }
        async let second = cache.value(for: "slow") {
            await counter.increment("slow")
            try await Task.sleep(for: .milliseconds(50))
            return 99
        }
        let results = try await (first, second)
        #expect(results.0 == 42)
        #expect(results.1 == 42)
        #expect(await counter.count("slow") == 1)
    }

    @Test func プリフェッチが完了すればヒットになる() async throws {
        let cache = LRUByteCache<String, Int>(byteLimit: 1000) { _ in 1 }
        let counter = LoadCounter()

        await cache.prefetch(key: "p") {
            await counter.increment("p")
            return 7
        }
        // プリフェッチ完了を待つ
        try await Task.sleep(for: .milliseconds(50))

        let value = try await cache.value(for: "p") {
            await counter.increment("p")
            return -1
        }
        #expect(value == 7)
        #expect(await counter.count("p") == 1)
    }

    @Test func プリフェッチのキャンセル後は再ロードできる() async throws {
        let cache = LRUByteCache<String, Int>(byteLimit: 1000) { _ in 1 }
        let counter = LoadCounter()

        await cache.prefetch(key: "victim") {
            await counter.increment("victim")
            try await Task.sleep(for: .seconds(10)) // キャンセルされるまで眠る
            return 1
        }
        try await Task.sleep(for: .milliseconds(20))
        await cache.cancelPrefetches(keeping: [])
        try await Task.sleep(for: .milliseconds(20))

        // キャンセル済みでも要求時には再ロードして値が返る
        let value = try await cache.value(for: "victim") {
            await counter.increment("victim")
            return 2
        }
        #expect(value == 2)
        #expect(await counter.count("victim") == 2)
    }

    @Test func keepingに含まれるプリフェッチはキャンセルされない() async throws {
        let cache = LRUByteCache<String, Int>(byteLimit: 1000) { _ in 1 }

        await cache.prefetch(key: "keep") {
            try await Task.sleep(for: .milliseconds(50))
            return 10
        }
        await cache.cancelPrefetches(keeping: ["keep"])

        let value = try await cache.value(for: "keep") { -1 }
        #expect(value == 10, "キャンセルされずプリフェッチ結果が使われるはず")
    }

    @Test func ローダーのエラーはキャッシュされない() async throws {
        struct TestError: Error {}
        let cache = LRUByteCache<String, Int>(byteLimit: 1000) { _ in 1 }

        await #expect(throws: TestError.self) {
            _ = try await cache.value(for: "e") { throw TestError() }
        }
        // エラー後は再試行できる
        let value = try await cache.value(for: "e") { 5 }
        #expect(value == 5)
    }

    @Test func コスト計算に基づく合計バイト管理() async throws {
        let cache = LRUByteCache<String, [UInt8]>(byteLimit: 100) { $0.count }
        _ = try await cache.value(for: "a") { [UInt8](repeating: 0, count: 40) }
        _ = try await cache.value(for: "b") { [UInt8](repeating: 0, count: 40) }
        var stats = await cache.currentStats()
        #expect(stats.totalBytes == 80)

        // 40バイト追加で上限超過 → 最古の a を追い出して 80 に戻る
        _ = try await cache.value(for: "c") { [UInt8](repeating: 0, count: 40) }
        stats = await cache.currentStats()
        #expect(stats.totalBytes == 80)
        #expect(stats.evictions == 1)
    }
}
