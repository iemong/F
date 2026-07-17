import Foundation
import Testing

@testable import AppCore

@Suite("近接カットの自動スタック")
struct PhotoStackerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ name: String, seconds: TimeInterval, hash: UInt64 = 0
    ) -> StackCandidate {
        StackCandidate(
            url: URL(fileURLWithPath: "/photos/\(name).DNG"),
            capturedAt: start.addingTimeInterval(seconds),
            sequenceNumber: PhotoStackAnalyzer.sequenceNumber(
                in: URL(fileURLWithPath: name)),
            perceptualHash: hash)
    }

    @Test func 近い時刻と連番をまとめる() {
        let candidates = [
            candidate("L1000001", seconds: 0),
            candidate("L1000002", seconds: 1),
            candidate("L1000003", seconds: 2),
            candidate("L1000010", seconds: 20),
        ]
        let stacks = PhotoStackAnalyzer.makeStacks(candidates: candidates)
        #expect(stacks.count == 1)
        #expect(stacks[0].members.count == 3)
    }

    @Test func 時刻または連番が離れた写真はまとめない() {
        let candidates = [
            candidate("L1000001", seconds: 0),
            candidate("L1000002", seconds: 10),
            candidate("L1000010", seconds: 11),
        ]
        #expect(PhotoStackAnalyzer.makeStacks(candidates: candidates).isEmpty)
    }

    @Test func perceptualHashで類似しないカットを分離する() {
        let candidates = [
            candidate("L1000001", seconds: 0, hash: 0),
            candidate("L1000002", seconds: 1, hash: .max),
        ]
        #expect(PhotoStackAnalyzer.makeStacks(candidates: candidates).isEmpty)
        #expect(PhotoStackAnalyzer.hammingDistance(0, .max) == 64)
    }

    @Test func ファイル末尾の連番を抽出する() {
        #expect(
            PhotoStackAnalyzer.sequenceNumber(
                in: URL(fileURLWithPath: "/photos/L1030505.DNG")) == 1_030_505)
        #expect(
            PhotoStackAnalyzer.sequenceNumber(
                in: URL(fileURLWithPath: "/photos/no-number.DNG")) == nil)
    }

    @Test func 折りたたみと展開でグリッド対象を切り替える() {
        let firstDNG = URL(fileURLWithPath: "/photos/L1000001.DNG")
        let firstJPG = URL(fileURLWithPath: "/photos/L1000001.JPG")
        let second = URL(fileURLWithPath: "/photos/L1000002.DNG")
        let other = URL(fileURLWithPath: "/photos/L1000010.DNG")
        let stack = PhotoStack(
            id: firstDNG.deletingPathExtension(), members: [firstDNG, second])
        let visible = [firstDNG, firstJPG, second, other]

        #expect(
            PhotoStackAnalyzer.gridFiles(
                visibleFiles: visible, stacks: [stack], expandedStackIDs: [])
                == [firstDNG, other])
        #expect(
            PhotoStackAnalyzer.gridFiles(
                visibleFiles: visible, stacks: [stack], expandedStackIDs: [stack.id])
                == [firstDNG, second, other])
    }
}
