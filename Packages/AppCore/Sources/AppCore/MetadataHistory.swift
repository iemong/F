import Foundation

public enum MetadataValue: Equatable, Sendable {
    case rating(Int)
    case label(String?)
    case keywords([String])
}

public struct MetadataEdit: Equatable, Sendable {
    public let imageURL: URL
    public let memberURLs: [URL]
    public let before: MetadataValue
    public let after: MetadataValue

    public init(
        imageURL: URL, memberURLs: [URL], before: MetadataValue, after: MetadataValue
    ) {
        self.imageURL = imageURL
        self.memberURLs = memberURLs
        self.before = before
        self.after = after
    }
}

public struct MetadataTransaction: Equatable, Sendable {
    public let edits: [MetadataEdit]
    public let focusURL: URL?

    public init(edits: [MetadataEdit], focusURL: URL?) {
        self.edits = edits
        self.focusURL = focusURL
    }
}

/// メタデータ操作単位の履歴。一括操作も1つのtransactionとして保持する。
public struct MetadataHistory: Sendable {
    private var undoStack: [MetadataTransaction] = []
    private var redoStack: [MetadataTransaction] = []
    private let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ transaction: MetadataTransaction) {
        guard !transaction.edits.isEmpty else { return }
        undoStack.append(transaction)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll(keepingCapacity: true)
    }

    public mutating func takeUndo() -> MetadataTransaction? {
        guard let transaction = undoStack.popLast() else { return nil }
        redoStack.append(transaction)
        return transaction
    }

    public mutating func takeRedo() -> MetadataTransaction? {
        guard let transaction = redoStack.popLast() else { return nil }
        undoStack.append(transaction)
        return transaction
    }

    public mutating func removeAll() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }
}
