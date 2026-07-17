import Foundation
import Testing

@testable import AppCore

@Suite("メタデータ履歴")
struct MetadataHistoryTests {
    private let dng = URL(fileURLWithPath: "/photos/L1000001.DNG")
    private let jpg = URL(fileURLWithPath: "/photos/L1000001.JPG")

    @Test func ペア変更を1操作としてUndoとRedoできる() {
        let edit = MetadataEdit(
            imageURL: dng, memberURLs: [dng, jpg],
            before: .rating(0), after: .rating(5))
        let transaction = MetadataTransaction(edits: [edit], focusURL: dng)
        var history = MetadataHistory()

        history.record(transaction)
        #expect(history.canUndo)
        #expect(history.takeUndo() == transaction)
        #expect(history.canRedo)
        #expect(history.takeRedo() == transaction)
    }

    @Test func 一括変更も1つのtransactionとして保持する() {
        let other = URL(fileURLWithPath: "/photos/L1000002.DNG")
        let transaction = MetadataTransaction(
            edits: [
                MetadataEdit(
                    imageURL: dng, memberURLs: [dng, jpg],
                    before: .label(nil), after: .label("Red")),
                MetadataEdit(
                    imageURL: other, memberURLs: [other],
                    before: .label(nil), after: .label("Red")),
            ], focusURL: dng)
        var history = MetadataHistory()
        history.record(transaction)

        #expect(history.takeUndo()?.edits.count == 2)
        #expect(!history.canUndo)
    }

    @Test func 新しい操作でRedo履歴を破棄する() {
        let first = MetadataTransaction(
            edits: [MetadataEdit(
                imageURL: dng, memberURLs: [dng],
                before: .rating(0), after: .rating(1))], focusURL: dng)
        let second = MetadataTransaction(
            edits: [MetadataEdit(
                imageURL: dng, memberURLs: [dng],
                before: .rating(0), after: .rating(2))], focusURL: dng)
        var history = MetadataHistory()
        history.record(first)
        _ = history.takeUndo()
        history.record(second)

        #expect(!history.canRedo)
    }
}
