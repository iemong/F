import Foundation
import Testing
import XMPKit

@testable import AppCore

@Suite("表示対象と選択位置")
struct LibrarySelectionTests {
    private let dng = URL(fileURLWithPath: "/photos/L1000001.DNG")
    private let jpg = URL(fileURLWithPath: "/photos/L1000001.JPG")
    private let other = URL(fileURLWithPath: "/photos/L1000002.DNG")

    @Test func ファイル種別を切り替えられる() {
        let files = [dng, jpg, other]
        #expect(LibrarySelection.typedFiles(files, mode: .dng) == [dng, other])
        #expect(LibrarySelection.typedFiles(files, mode: .jpg) == [jpg])
        #expect(LibrarySelection.typedFiles(files, mode: .both) == files)
    }

    @Test func 複数フィルターを同時適用する() {
        let files = [dng, jpg, other]
        let filter = FilterState(
            minRating: 3, hideRejected: true, label: "Red", keyword: "旅行")
        let visible = LibrarySelection.visibleFiles(
            files,
            mode: .both,
            filter: filter,
            ratings: [dng: 4, jpg: 4, other: -1],
            labels: [dng: "Red", jpg: "Blue", other: "Red"],
            keywords: [dng: ["旅行"], jpg: ["旅行"], other: ["旅行"]])
        #expect(visible == [dng])
    }

    @Test func 種別切替時に同じショットのペアへ移る() {
        let index = LibrarySelection.reselectedIndex(
            previous: dng, currentIndex: 8, visibleFiles: [jpg, other])
        #expect(index == 0)
    }

    @Test func 選択対象が無ければ範囲内へクランプする() {
        #expect(
            LibrarySelection.reselectedIndex(
                previous: nil, currentIndex: 10, visibleFiles: [dng, other]) == 1)
        #expect(
            LibrarySelection.reselectedIndex(
                previous: nil, currentIndex: 10, visibleFiles: []) == 0)
    }

    @Test func 同じディレクトリとbasenameだけをペアにする() {
        let elsewhere = URL(fileURLWithPath: "/elsewhere/L1000001.JPG")
        #expect(
            LibrarySelection.pairedURLs(of: dng, in: [dng, jpg, elsewhere, other])
                == [dng, jpg])
    }
}

@Suite("ゴミ箱計画")
struct TrashPlanTests {
    @Test func ペア相手が残る場合は共有XMPを残す() {
        let dng = URL(fileURLWithPath: "/photos/L1000001.DNG")
        let jpg = URL(fileURLWithPath: "/photos/L1000001.JPG")
        let plan = LibraryOperations.trashPlan(
            rejectedURLs: [dng], allFiles: [dng, jpg])

        #expect(plan.imageURLs == [dng])
        #expect(plan.sidecarURLs.isEmpty)
    }

    @Test func ペアを両方捨てる場合は共有XMPも対象にする() {
        let dng = URL(fileURLWithPath: "/photos/L1000001.DNG")
        let jpg = URL(fileURLWithPath: "/photos/L1000001.JPG")
        let plan = LibraryOperations.trashPlan(
            rejectedURLs: [dng, jpg], allFiles: [dng, jpg])

        #expect(plan.sidecarURLs == [XMPSidecar.url(for: dng)])
    }
}

@Suite("画像ファイル列挙")
struct ImageDiscoveryTests {
    @Test func 再帰列挙と上限が機能する() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDiscovery-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("DCIM/100LEICA", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["L1.DNG", "L2.JPG", "L3.JPEG", "memo.txt"] {
            try Data().write(to: nested.appendingPathComponent(name))
        }
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data().write(to: hidden.appendingPathComponent("hidden.DNG"))

        let all = ImageDiscovery.findImages(in: root)
        #expect(all.map(\.lastPathComponent) == ["L1.DNG", "L2.JPG", "L3.JPEG"])
        #expect(ImageDiscovery.findImages(in: root, limit: 2).count == 2)
    }
}
