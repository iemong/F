import AppKit
import AppCore
import CacheKit
import Foundation
import Observation
import QuartzCore
import XMPKit
import os

enum ZoomMode {
    case fit
    /// 100%ピクセル等倍（1シーンpx = 1デバイスpx）
    case actualSize
}

enum ViewMode {
    case grid
    case single
    case comparison
}

/// キャッシュキー: 通常表示(display)と100%等倍用フル解像(full)を区別する
struct FrameKey: Hashable, Sendable {
    let url: URL
    let full: Bool
}

/// SDカード等の外部ボリューム
struct RemovableVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    var id: URL { url }
}

/// カラーラベル（Lightroom互換のxmp:Label値とキー割当 6-9）
enum ColorLabel {
    static let all: [(key: String, value: String)] = [
        ("6", "Red"), ("7", "Yellow"), ("8", "Green"), ("9", "Blue"),
    ]
}

extension FileTypeMode {
    var displayName: String {
        switch self {
        case .dng: "DNG"
        case .jpg: "JPG"
        case .both: "両方"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var files: [URL] = []
    private(set) var currentIndex = 0
    private(set) var currentFrame: PresentedFrame?
    private(set) var statusText = ""
    private(set) var latencyText = ""
    private(set) var viewMode: ViewMode = .single
    private(set) var zoomMode: ZoomMode = .fit
    /// 比較候補は配列で保持し、将来の4枚比較へ拡張可能にする。
    private(set) var comparisonURLs: [URL] = []
    private(set) var comparisonFrames: [URL: PresentedFrame] = [:]
    /// グリッドで一括操作する選択。フィルター変更時は表示中の要素との共通部分を残す。
    private(set) var gridSelection: Set<URL> = []
    @ObservationIgnored private var gridSelectionAnchor: URL?
    /// グリッドの列数（ビュー側のレイアウトから通知される。上下キー移動に使う）
    var gridColumns = 5
    /// グリッドのセルサイズ（スライダーで変更、UserDefaultsに永続化）
    var gridCellSize: CGFloat = 196 {
        didSet {
            UserDefaults.standard.set(Double(gridCellSize), forKey: "gridCellSize")
        }
    }
    /// 撮影情報パネル（Iキー）の表示状態（UserDefaultsに永続化）
    var showInfoPanel = false {
        didSet {
            UserDefaults.standard.set(showInfoPanel, forKey: "showInfoPanel")
        }
    }
    /// フィルムストリップ（Fキー）の表示状態（UserDefaultsに永続化、既定は表示）
    var showFilmstrip = true {
        didSet {
            UserDefaults.standard.set(showFilmstrip, forKey: "showFilmstrip")
        }
    }
    /// 現在の画面で使える主要ショートカットを示す下部バー（既定は表示）
    var showShortcutBar = true {
        didSet {
            UserDefaults.standard.set(showShortcutBar, forKey: "showShortcutBar")
        }
    }
    /// レート・除外・カラーラベル変更後に次の写真へ進む（既定は無効）
    var autoAdvanceAfterRating = false {
        didSet {
            UserDefaults.standard.set(autoAdvanceAfterRating, forKey: "autoAdvanceAfterRating")
        }
    }
    /// 撮影時刻・連番・軽量画像ハッシュによる近接カットの自動スタック（既定は無効）
    var autoStackNearbyShots = false {
        didSet {
            UserDefaults.standard.set(autoStackNearbyShots, forKey: "autoStackNearbyShots")
            scheduleStackAnalysis()
        }
    }
    /// 既存サムネイルを利用する軽量な技術品質解析（既定は無効）
    var analyzeTechnicalQuality = false {
        didSet {
            UserDefaults.standard.set(analyzeTechnicalQuality, forKey: "analyzeTechnicalQuality")
            scheduleQualityAnalysis()
        }
    }
    /// 表示するファイル種別（UserDefaultsに永続化、既定はDNGのみ）。
    /// 変更は setFileTypeMode 経由（選択位置の引き継ぎがあるため）
    private(set) var fileTypeMode: FileTypeMode = .dng {
        didSet {
            UserDefaults.standard.set(fileTypeMode.rawValue, forKey: "fileTypeMode")
        }
    }
    private(set) var currentFolder: URL?
    /// マウント中のSDカード等（NSWorkspaceの通知で更新）
    private(set) var removableVolumes: [RemovableVolume] = []
    private(set) var recentFolders: [URL] = []

    var windowTitle: String {
        currentFolder?.lastPathComponent ?? "F"
    }
    /// URL → レート（1-5、-1=除外。0/未登録=なし）。XMPサイドカーと同期
    private(set) var ratings: [URL: Int] = [:]
    /// URL → カラーラベル（"Red"等）。XMPサイドカーと同期
    private(set) var labels: [URL: String] = [:]
    /// URL → キーワード（任意名タグ、dc:subject）。XMPサイドカーと同期
    private(set) var keywords: [URL: [String]] = [:]
    private(set) var filter = FilterState()

    /// キーワード編集シート（Tキー）
    var isEditingKeywords = false
    var keywordDraft = ""

    /// エクスポートシート（⌘E）
    var isExportSheetPresented = false
    /// nil = エクスポート実行中でない
    private(set) var exportProgress: ExportProgress?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    /// 除外(✕)のゴミ箱移動の確認ダイアログ
    var isConfirmingTrash = false

    /// XMPのread-modify-writeを直列化し、キー連打時の更新逆転を防ぐ
    @ObservationIgnored private let xmpWriter = XMPWriteCoordinator()
    @ObservationIgnored private var xmpWriteRevision: UInt64 = 0
    @ObservationIgnored private var metadataHistory = MetadataHistory()
    private(set) var canUndoMetadata = false
    private(set) var canRedoMetadata = false
    private(set) var photoStacks: [PhotoStack] = []
    private(set) var expandedStackIDs: Set<URL> = []
    @ObservationIgnored private let selectionAssistCache = SelectionAssistCache()
    @ObservationIgnored private var stackAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var stackAnalysisGeneration = 0
    private(set) var qualityByURL: [URL: QualityMetrics] = [:]
    @ObservationIgnored private var qualityAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var qualityAnalysisGeneration = 0

    /// ファイル種別モード適用後の全ファイル。「全n件」表示やエクスポート対象の基底
    var typedFiles: [URL] {
        LibrarySelection.typedFiles(files, mode: fileTypeMode)
    }

    /// 種別モード+フィルター適用後の表示・送り対象。グリッドとナビゲーションはこちらを使う
    var visibleFiles: [URL] {
        LibrarySelection.visibleFiles(
            files,
            mode: fileTypeMode,
            filter: filter,
            ratings: ratings,
            labels: labels,
            keywords: keywords)
    }

    /// グリッド専用の表示対象。折りたたみ中は各スタックの代表写真だけを返す。
    var gridVisibleFiles: [URL] {
        let visible = visibleFiles
        guard autoStackNearbyShots, !photoStacks.isEmpty else { return visible }
        return PhotoStackAnalyzer.gridFiles(
            visibleFiles: visible, stacks: photoStacks,
            expandedStackIDs: expandedStackIDs)
    }

    func stack(for url: URL) -> PhotoStack? {
        let base = url.deletingPathExtension()
        return photoStacks.first { stack in
            stack.members.contains { $0.deletingPathExtension() == base }
        }
    }

    func toggleStack(containing url: URL) {
        guard let stack = stack(for: url) else { return }
        if !expandedStackIDs.insert(stack.id).inserted {
            expandedStackIDs.remove(stack.id)
        }
    }

    func qualityRank(for url: URL, in stack: PhotoStack?) -> (rank: Int, total: Int)? {
        guard autoStackNearbyShots, analyzeTechnicalQuality, let stack else { return nil }
        let scored = stack.members.compactMap { member in
            qualityByURL[member].map { (member, $0.overallScore) }
        }.sorted { $0.1 > $1.1 }
        guard scored.count == stack.members.count,
            let index = scored.firstIndex(where: { $0.0 == url })
        else { return nil }
        return (index + 1, scored.count)
    }

    var positionText: String {
        let visible = visibleFiles
        guard !visible.isEmpty || filter.isActive else { return "" }
        let base = visible.isEmpty ? "0/0" : "\(currentIndex + 1)/\(visible.count)"
        return filter.isActive ? base + " (全\(typedFiles.count))" : base
    }

    var selectionProgressText: String {
        let progress = LibrarySelection.selectionProgress(
            files, mode: fileTypeMode, ratings: ratings)
        guard progress.total > 0 else { return "" }
        return "選別済み \(progress.evaluated) / \(progress.total)"
    }

    var fileNameText: String {
        currentFrame?.frame.fileName ?? ""
    }

    var ratingText: String {
        guard let url = currentURL, let rating = ratings[url], rating != 0 else { return "" }
        return rating == -1 ? "✕ 除外" : String(repeating: "★", count: rating)
    }

    var zoomText: String {
        guard viewMode == .single, zoomMode == .actualSize else { return "" }
        let resolved = currentFrame?.frame.isFullResolution == true
        return resolved ? "100%" : "100%(展開中…)"
    }

    var currentURL: URL? {
        let visible = visibleFiles
        return visible.indices.contains(currentIndex) ? visible[currentIndex] : nil
    }

    var currentLabel: String? {
        currentURL.flatMap { labels[$0] }
    }

    var currentKeywords: [String] {
        currentURL.flatMap { keywords[$0] } ?? []
    }

    /// フォルダ内の全キーワード（フィルターメニューと編集サジェスト用）
    var allFolderKeywords: [String] {
        var counts: [String: Int] = [:]
        for list in keywords.values {
            for keyword in list { counts[keyword, default: 0] += 1 }
        }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    }

    // MARK: - キーワード編集（Tキー）

    func beginKeywordEditing() {
        guard let url = metadataTargetURLs.first else { return }
        let targets = metadataTargetURLs
        let common = targets.dropFirst().reduce(Set(keywords[url] ?? [])) { result, target in
            result.intersection(keywords[target] ?? [])
        }
        keywordDraft = (targets.count == 1 ? (keywords[url] ?? []) : Array(common).sorted())
            .joined(separator: ", ")
        isEditingKeywords = true
    }

    func commitKeywordEditing() {
        defer { isEditingKeywords = false }
        let targets = metadataShotTargets
        guard let url = targets.first?.imageURL else { return }
        var seen = Set<String>()
        let parsed = keywordDraft
            .split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let edits = targets.compactMap { target -> MetadataEdit? in
            let before = keywords[target.imageURL] ?? []
            guard parsed != before else { return nil }
            return MetadataEdit(
                imageURL: target.imageURL, memberURLs: target.memberURLs,
                before: .keywords(before), after: .keywords(parsed))
        }
        applyNewMetadataTransaction(edits, focusURL: url)
    }

    func cancelKeywordEditing() {
        isEditingKeywords = false
    }

    /// フィルター変更。選択中のファイルが残っていれば選択を維持する
    func setFilter(_ newFilter: FilterState) {
        guard newFilter != filter else { return }
        let selected = currentURL
        filter = newFilter
        gridSelection.formIntersection(visibleFiles)
        reselect(previous: selected)
    }

    /// 現在の他フィルターは維持し、評価状態だけを「未評価」にして次候補へ移る。
    /// 末尾からは先頭へ循環する。
    func moveToNextUnrated() {
        let previousURL = currentURL
        var candidateFilter = filter
        candidateFilter.evaluation = .unrated
        let candidates = LibrarySelection.visibleFiles(
            files, mode: fileTypeMode, filter: candidateFilter, ratings: ratings,
            labels: labels, keywords: keywords)
        guard !candidates.isEmpty else {
            statusText = "未評価の写真はありません"
            return
        }

        let typed = typedFiles
        let previousTypedIndex = previousURL.flatMap { typed.firstIndex(of: $0) } ?? -1
        let destination = candidates.first {
            (typed.firstIndex(of: $0) ?? -1) > previousTypedIndex
        } ?? candidates[0]
        filter = candidateFilter
        currentIndex = candidates.firstIndex(of: destination) ?? 0
        statusText = ""
        if viewMode == .single { loadCurrent() }
    }

    /// ファイル種別モードの切替。選択中のファイルが消える場合は
    /// 同basenameのペア相手（DNG⇔JPG）へ選択を引き継ぐ
    func setFileTypeMode(_ mode: FileTypeMode) {
        guard mode != fileTypeMode else { return }
        let selected = currentURL
        fileTypeMode = mode
        reselect(previous: selected)
        scheduleStackAnalysis()
        scheduleQualityAnalysis()
    }

    /// 表示対象リストが変わった後（フィルター/種別切替）の選択位置の整合
    private func reselect(previous selected: URL?) {
        let visible = visibleFiles
        currentIndex = LibrarySelection.reselectedIndex(
            previous: selected, currentIndex: currentIndex, visibleFiles: visible)
        if viewMode == .single {
            if visible.isEmpty {
                viewMode = .grid
            } else if visible[currentIndex] != selected {
                loadCurrent()
            }
        }
    }

    /// グリッドのサムネイル供給（LRU 320MB）
    @ObservationIgnored let thumbnails = ThumbnailProvider()

    /// 撮影情報パネルの供給（Iキー、URLキーでキャッシュ）
    @ObservationIgnored let captureInfoProvider = CaptureInfoProvider()

    /// テクスチャキャッシュ（上限2GB、コスト=テクスチャバイト数）。
    /// 通常表示とフル解像（等倍用）を FrameKey で区別して同居させる
    @ObservationIgnored private let cache = LRUByteCache<FrameKey, TextureFrame>(
        byteLimit: 2 * 1024 * 1024 * 1024
    ) { $0.byteCost }

    /// 近傍フレームの MainActor 側ミラー。
    /// キー送りのヒット時に actor ホップを挟まず同一ランループで表示を確定させ、
    /// vsync 1フレーム分のレイテンシに抑えるために持つ（実体は cache と共有）
    @ObservationIgnored private var hotFrames: [URL: TextureFrame] = [:]

    /// 表示中の MetalLayerView への直結参照。SwiftUI の更新サイクル
    /// （+1フレーム）を待たずに同一ランループで描画するための高速経路
    @ObservationIgnored private weak var renderView: MetalLayerView?
    @ObservationIgnored private weak var comparisonLeftView: MetalLayerView?
    @ObservationIgnored private weak var comparisonRightView: MetalLayerView?

    func registerRenderView(_ view: MetalLayerView) {
        renderView = view
    }

    func registerComparisonView(_ view: MetalLayerView, slot: Int) {
        if slot == 0 { comparisonLeftView = view } else { comparisonRightView = view }
    }

    func synchronizeComparisonPan(_ offset: CGPoint) {
        guard viewMode == .comparison else { return }
        comparisonLeftView?.setPanOffset(offset)
        comparisonRightView?.setPanOffset(offset)
    }

    /// 直近のキー送り方向（+1/-1）。先読み窓をこの向きに寄せる
    @ObservationIgnored private var lastNavigationDirection = 1
    @ObservationIgnored private var generation = 0
    /// 速報（埋め込みプレビュー）を表示した世代。本デコード完了時の差し替え判定に使う
    @ObservationIgnored private var provisionalGeneration = -1
    /// 本フレームを表示済みの世代。遅れて届いた速報が本フレームを上書きしないためのガード
    @ObservationIgnored private var realFrameGeneration = -1
    @ObservationIgnored private var navigationStart: ContinuousClock.Instant?
    /// presentedTime との差分計算用（CACurrentMediaTime 基準）
    @ObservationIgnored private var navigationStartMedia: CFTimeInterval = 0
    /// アプリ側処理（キー→描画コマンドcommit完了）の所要ms。
    /// glass時間との差はOSコンポジタ+vsync由来でアプリでは制御できない
    @ObservationIgnored private var lastWorkMS: Double = 0
    @ObservationIgnored private var lastDecodeDuration: Duration = .zero
    @ObservationIgnored private let signposter = OSSignposter(
        subsystem: "F.App", category: "navigation")
    @ObservationIgnored private var navigateState: OSSignpostIntervalState?

    private enum AutotestPhase {
        case forward, backward
    }
    @ObservationIgnored private var isAutotest = false
    @ObservationIgnored private var autotestPhase: AutotestPhase = .forward
    @ObservationIgnored private var pass1Latencies: [Double] = []
    @ObservationIgnored private var pass2Latencies: [Double] = []

    /// @State の初期値式は nonisolated コンテキストで評価されるため
    nonisolated init() {}

    /// 起動引数の処理（開発・検証用）:
    /// --folder <path>  起動時にそのフォルダを開く（NSOpenPanel省略）
    /// --autotest       全ファイルを往復自動送り（往路=先読み込み、復路=全ヒット）して
    ///                  レイテンシを標準出力へ、完了後に終了
    func bootstrap() {
        refreshRemovableVolumes()
        observeVolumeChanges()
        loadRecentFolders()
        let savedCellSize = UserDefaults.standard.double(forKey: "gridCellSize")
        if savedCellSize >= 120 { gridCellSize = savedCellSize }
        showInfoPanel = UserDefaults.standard.bool(forKey: "showInfoPanel")
        if UserDefaults.standard.object(forKey: "showFilmstrip") != nil {
            showFilmstrip = UserDefaults.standard.bool(forKey: "showFilmstrip")
        }
        if UserDefaults.standard.object(forKey: "showShortcutBar") != nil {
            showShortcutBar = UserDefaults.standard.bool(forKey: "showShortcutBar")
        }
        if UserDefaults.standard.object(forKey: "autoAdvanceAfterRating") != nil {
            autoAdvanceAfterRating = UserDefaults.standard.bool(
                forKey: "autoAdvanceAfterRating")
        }
        if UserDefaults.standard.object(forKey: "autoStackNearbyShots") != nil {
            autoStackNearbyShots = UserDefaults.standard.bool(forKey: "autoStackNearbyShots")
        }
        if UserDefaults.standard.object(forKey: "analyzeTechnicalQuality") != nil {
            analyzeTechnicalQuality = UserDefaults.standard.bool(
                forKey: "analyzeTechnicalQuality")
        }
        if let saved = UserDefaults.standard.string(forKey: "fileTypeMode"),
            let mode = FileTypeMode(rawValue: saved)
        {
            fileTypeMode = mode
        }

        let arguments = CommandLine.arguments
        isAutotest = arguments.contains("--autotest")
        if isAutotest {
            // パイプ先でも進捗が流れるように行バッファへ（既定はフルバッファで
            // ハング時に停止地点が見えない）
            setlinebuf(stdout)
        }
        if let flagIndex = arguments.firstIndex(of: "--folder"),
            arguments.indices.contains(flagIndex + 1)
        {
            loadFolder(URL(fileURLWithPath: arguments[flagIndex + 1], isDirectory: true))
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "DNGファイルのあるフォルダを選択"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url)
    }

    /// 最近使ったフォルダ・ボリュームメニューからの遷移
    func openFolder(at url: URL) {
        loadFolder(url)
    }

    /// SDカード等のボリュームを開く。DCIM があればそちらを起点にする
    func openVolume(_ volume: RemovableVolume) {
        let dcim = volume.url.appendingPathComponent("DCIM", isDirectory: true)
        let target =
            FileManager.default.fileExists(atPath: dcim.path) ? dcim : volume.url
        loadFolder(target)
    }

    private func loadFolder(_ url: URL) {
        currentFolder = url
        files = []
        currentIndex = 0
        currentFrame = nil
        latencyText = ""
        ratings = [:]
        labels = [:]
        keywords = [:]
        filter = FilterState()
        photoStacks = []
        expandedStackIDs = []
        stackAnalysisTask?.cancel()
        qualityByURL = [:]
        qualityAnalysisTask?.cancel()
        metadataHistory.removeAll()
        updateHistoryAvailability()
        zoomMode = .fit
        statusText = "読み込み中…"

        // SDカードは DCIM/100LEICA/ のようにサブフォルダに入るため再帰で探す。
        // 大きいツリーやUSB越しでも固まらないよう列挙はバックグラウンド
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = ImageDiscovery.findImages(in: url)
            await self?.applyFolderContents(found, for: url)
        }
    }

    private func applyFolderContents(_ found: [URL], for url: URL) {
        guard currentFolder == url else { return } // 列挙中に別フォルダへ移動した
        files = found
        statusText = files.isEmpty ? "DNG/JPGが見つかりません" : ""
        if !files.isEmpty {
            addRecentFolder(url)
            // 仕様: フォルダを開く → サムネグリッド（autotestは1枚表示で計測）
            if isAutotest {
                viewMode = .single
                loadCurrent()
            } else {
                viewMode = .grid
            }
            restoreRatings(for: files)
            scheduleStackAnalysis()
            scheduleQualityAnalysis()
        }
    }

    // MARK: - ボリューム / 最近使ったフォルダ

    private func refreshRemovableVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        removableVolumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let external =
                (values.volumeIsRemovable ?? false)
                || (values.volumeIsEjectable ?? false)
                || !(values.volumeIsInternal ?? true)
            guard external else { return nil }
            return RemovableVolume(url: url, name: values.volumeName ?? url.lastPathComponent)
        }
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRemovableVolumes() }
            }
        }
    }

    private static let recentFoldersKey = "recentFolders"

    private func loadRecentFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []
        recentFolders = paths
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecentFolder(_ url: URL) {
        var recents = recentFolders.filter { $0 != url }
        recents.insert(url, at: 0)
        recentFolders = Array(recents.prefix(5))
        UserDefaults.standard.set(
            recentFolders.map(\.path), forKey: Self.recentFoldersKey)
    }

    /// 既存XMPサイドカーからレートとラベルを復元する
    private func restoreRatings(for urls: [URL]) {
        Task.detached(priority: .utility) { [weak self] in
            var restoredRatings: [URL: Int] = [:]
            var restoredLabels: [URL: String] = [:]
            var restoredKeywords: [URL: [String]] = [:]
            for url in urls {
                if let rating = XMPSidecar.readRating(forImageAt: url), rating != 0 {
                    restoredRatings[url] = rating
                }
                if let label = XMPSidecar.readLabel(forImageAt: url) {
                    restoredLabels[url] = label
                }
                let kws = XMPSidecar.readKeywords(forImageAt: url)
                if !kws.isEmpty { restoredKeywords[url] = kws }
            }
            guard !restoredRatings.isEmpty || !restoredLabels.isEmpty || !restoredKeywords.isEmpty
            else { return }
            await self?.applyRestoredMetadata(
                ratings: restoredRatings, labels: restoredLabels,
                keywords: restoredKeywords, expecting: urls)
        }
    }

    private func applyRestoredMetadata(
        ratings restoredRatings: [URL: Int],
        labels restoredLabels: [URL: String],
        keywords restoredKeywords: [URL: [String]],
        expecting urls: [URL]
    ) {
        guard files == urls else { return } // 復元中に別フォルダへ移動していたら破棄
        ratings.merge(restoredRatings) { current, _ in current } // セッション中の変更を優先
        labels.merge(restoredLabels) { current, _ in current }
        keywords.merge(restoredKeywords) { current, _ in current }
    }

    // MARK: - 近接カットの自動スタック

    private func scheduleStackAnalysis() {
        stackAnalysisGeneration += 1
        let requestedGeneration = stackAnalysisGeneration
        stackAnalysisTask?.cancel()
        guard autoStackNearbyShots, !files.isEmpty else {
            photoStacks = []
            expandedStackIDs = []
            return
        }

        var seen = Set<URL>()
        let urls = typedFiles.filter { seen.insert($0.deletingPathExtension()).inserted }
        let provider = captureInfoProvider
        let thumbnails = thumbnails
        let assistCache = selectionAssistCache
        stackAnalysisTask = Task { [weak self] in
            var candidates: [StackCandidate] = []
            var updates: [URL: AssistCacheEntry] = [:]
            for url in urls {
                guard !Task.isCancelled, let fingerprint = FileFingerprint.read(from: url)
                else { return }
                let cached = await assistCache.entry(for: url, fingerprint: fingerprint)
                let entry: AssistCacheEntry
                if let cached {
                    entry = cached
                } else {
                    let info = await provider.info(for: url)
                    let thumbnail = await thumbnails.image(for: url)
                    entry = AssistCacheEntry(
                        fingerprint: fingerprint,
                        capturedAt: ExifDateParser.parse(info?.capture.dateTimeOriginal)?
                            .timeIntervalSince1970,
                        sequenceNumber: PhotoStackAnalyzer.sequenceNumber(in: url),
                        perceptualHash: thumbnail.flatMap {
                            ThumbnailAnalysis.perceptualHash(of: $0.cgImage)
                        },
                        quality: nil)
                    updates[url] = entry
                }
                candidates.append(
                    StackCandidate(
                        url: url,
                        capturedAt: entry.capturedAt.map(Date.init(timeIntervalSince1970:)),
                        sequenceNumber: entry.sequenceNumber,
                        perceptualHash: entry.perceptualHash))
            }
            await assistCache.update(updates)
            guard !Task.isCancelled else { return }
            let stacks = PhotoStackAnalyzer.makeStacks(candidates: candidates)
            self?.applyPhotoStacks(stacks, generation: requestedGeneration)
        }
    }

    private func applyPhotoStacks(_ stacks: [PhotoStack], generation: Int) {
        guard generation == stackAnalysisGeneration, autoStackNearbyShots else { return }
        photoStacks = stacks
        expandedStackIDs.formIntersection(stacks.map(\.id))
    }

    // MARK: - 技術品質解析

    private func scheduleQualityAnalysis(after delay: Duration = .milliseconds(700)) {
        qualityAnalysisGeneration += 1
        let requestedGeneration = qualityAnalysisGeneration
        qualityAnalysisTask?.cancel()
        guard analyzeTechnicalQuality, !files.isEmpty else {
            qualityByURL = [:]
            return
        }

        let urls = typedFiles
        let provider = captureInfoProvider
        let thumbnails = thumbnails
        let assistCache = selectionAssistCache
        qualityAnalysisTask = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            var updates: [URL: AssistCacheEntry] = [:]
            for url in urls {
                guard !Task.isCancelled, let fingerprint = FileFingerprint.read(from: url)
                else { return }
                let cached = await assistCache.entry(for: url, fingerprint: fingerprint)
                if let metrics = cached?.quality {
                    self?.applyQualityMetrics(
                        metrics, for: url, generation: requestedGeneration)
                    continue
                }

                guard let thumbnail = await thumbnails.image(for: url) else { continue }
                let metrics = await Task.detached(priority: .background) {
                    ThumbnailAnalysis.qualityMetrics(of: thumbnail.cgImage)
                }.value
                guard !Task.isCancelled, let metrics else { return }
                let info = await provider.info(for: url)
                let entry = AssistCacheEntry(
                    fingerprint: fingerprint,
                    capturedAt: cached?.capturedAt
                        ?? ExifDateParser.parse(info?.capture.dateTimeOriginal)?
                            .timeIntervalSince1970,
                    sequenceNumber: cached?.sequenceNumber
                        ?? PhotoStackAnalyzer.sequenceNumber(in: url),
                    perceptualHash: cached?.perceptualHash
                        ?? ThumbnailAnalysis.perceptualHash(of: thumbnail.cgImage),
                    quality: metrics)
                updates[url] = entry
                self?.applyQualityMetrics(
                    metrics, for: url, generation: requestedGeneration)
            }
            await assistCache.update(updates)
        }
    }

    private func applyQualityMetrics(
        _ metrics: QualityMetrics, for url: URL, generation: Int
    ) {
        guard generation == qualityAnalysisGeneration, analyzeTechnicalQuality,
            files.contains(url)
        else { return }
        qualityByURL[url] = metrics
    }

    private func pauseQualityAnalysisForInteraction() {
        guard analyzeTechnicalQuality else { return }
        qualityAnalysisTask?.cancel()
        scheduleQualityAnalysis(after: .milliseconds(900))
    }

    func navigate(_ delta: Int) {
        pauseQualityAnalysisForInteraction()
        if viewMode == .comparison {
            navigateComparisonCandidate(delta)
            return
        }
        let visible = visibleFiles
        guard !visible.isEmpty else { return }
        let newIndex = min(max(currentIndex + delta, 0), visible.count - 1)
        guard newIndex != currentIndex else { return }
        lastNavigationDirection = newIndex > currentIndex ? 1 : -1
        currentIndex = newIndex

        // グリッド中は選択移動のみ（重いロードはしない）
        guard viewMode == .single else { return }

        // ホットミラーにあれば同一ランループで表示確定（先読みヒットの高速経路）
        let url = visible[currentIndex]
        if let hot = hotFrames[url] {
            generation += 1
            navigationStart = ContinuousClock.now
            navigationStartMedia = CACurrentMediaTime()
            navigateState = signposter.beginInterval("navigate")
            lastDecodeDuration = hot.decodeDuration
            let presented = PresentedFrame(generation: generation, frame: hot)
            currentFrame = presented
            statusText = ""
            // SwiftUIの次回更新を待たず、このランループで直接描画（次のvsyncでpresent）
            renderView?.show(presented)
            lastWorkMS = (CACurrentMediaTime() - navigationStartMedia) * 1000
            let cache = cache
            Task { [weak self] in
                // LRUの使用時刻とヒット統計を更新（実体は既にキャッシュ内）
                _ = try? await cache.value(for: FrameKey(url: url, full: false)) { hot }
                await self?.schedulePrefetch()
            }
            if zoomMode == .actualSize {
                ensureFullResolution()
            }
            return
        }
        loadCurrent()
    }

    private func navigateComparisonCandidate(_ delta: Int) {
        guard comparisonURLs.count >= 2 else { return }
        let visible = visibleFiles
        guard let current = visible.firstIndex(of: comparisonURLs[1]) else { return }
        var candidate = min(max(current + delta, 0), visible.count - 1)
        if visible[candidate] == comparisonURLs[0] {
            candidate = min(max(candidate + delta, 0), visible.count - 1)
        }
        guard visible[candidate] != comparisonURLs[1], visible[candidate] != comparisonURLs[0]
        else { return }
        let winner = comparisonURLs[0]
        comparisonURLs = [winner, visible[candidate]]
        comparisonFrames = comparisonFrames.filter { $0.key == winner }
        loadComparisonFrames(fullResolution: zoomMode == .actualSize)
    }

    /// フィルムストリップ等からの任意位置ジャンプ。
    /// 隣接位置ならホットミラーの高速経路がそのまま効く
    func jumpTo(_ index: Int) {
        guard visibleFiles.indices.contains(index) else { return }
        navigate(index - currentIndex)
    }

    /// 表示用デコードの目標長辺（px）。最大解像度スクリーンの長辺基準で、
    /// これを超える全画素デコードはfit表示に寄与しない（等倍はfull経路が担う）。
    /// FrameKey にはターゲットを含めないため、スクリーン構成の変更直後は
    /// 旧ターゲットのキャッシュが残り得るが、LRUで自然に入れ替わる
    private var displayTargetPixels: Int {
        let side =
            NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2560
        return Int(side)
    }

    /// グリッド: 上下キーで1行分移動
    func moveSelectionVertically(_ rows: Int) {
        let grid = gridVisibleFiles
        guard viewMode == .grid, !grid.isEmpty else { return }
        let selectedGridIndex = currentURL.flatMap { grid.firstIndex(of: $0) } ?? 0
        let newIndex = min(max(selectedGridIndex + rows * gridColumns, 0), grid.count - 1)
        if let visibleIndex = visibleFiles.firstIndex(of: grid[newIndex]) {
            currentIndex = visibleIndex
        }
    }

    func select(_ index: Int) {
        guard visibleFiles.indices.contains(index) else { return }
        gridSelection.removeAll(keepingCapacity: true)
        currentIndex = index
        gridSelectionAnchor = visibleFiles[index]
    }

    func selectGridItem(_ url: URL, command: Bool, shift: Bool) {
        let grid = gridVisibleFiles
        guard let index = grid.firstIndex(of: url),
            let visibleIndex = visibleFiles.firstIndex(of: url)
        else { return }
        if shift, let anchor = gridSelectionAnchor,
            let anchorIndex = grid.firstIndex(of: anchor)
        {
            let range = min(anchorIndex, index) ... max(anchorIndex, index)
            gridSelection.formUnion(range.map { grid[$0] })
        } else if command {
            if gridSelection.isEmpty, let selected = currentURL, selected != url {
                gridSelection.insert(selected)
            }
            if !gridSelection.insert(url).inserted { gridSelection.remove(url) }
            gridSelectionAnchor = url
        } else {
            gridSelection.removeAll(keepingCapacity: true)
            gridSelectionAnchor = url
        }
        currentIndex = visibleIndex
    }

    /// グリッドから1枚表示へ
    func openSelected() {
        guard !visibleFiles.isEmpty else { return }
        viewMode = .single
        gridSelection.removeAll(keepingCapacity: true)
        loadCurrent()
    }

    /// 1枚表示・比較表示からグリッドへ
    func showGrid() {
        guard viewMode != .grid else { return }
        viewMode = .grid
        zoomMode = .fit
        comparisonURLs = []
        comparisonFrames = [:]
    }

    /// Z / Space: fit ⇔ 100%等倍
    func toggleZoom() {
        guard viewMode != .grid else { return }
        zoomMode = zoomMode == .fit ? .actualSize : .fit
        if viewMode == .comparison {
            comparisonLeftView?.setZoomMode(zoomMode)
            comparisonRightView?.setZoomMode(zoomMode)
            if zoomMode == .actualSize { loadComparisonFrames(fullResolution: true) }
        } else {
            renderView?.setZoomMode(zoomMode)
        }
        if viewMode == .single, zoomMode == .actualSize {
            ensureFullResolution()
        }
    }

    func beginComparison() {
        let selected = visibleFiles.filter { gridSelection.contains($0) }
        let candidates: [URL]
        if selected.count >= 2 {
            candidates = Array(selected.prefix(2))
        } else if visibleFiles.indices.contains(currentIndex),
            visibleFiles.indices.contains(currentIndex + 1)
        {
            candidates = [visibleFiles[currentIndex], visibleFiles[currentIndex + 1]]
        } else {
            statusText = "比較する写真を2枚選択してください"
            return
        }
        beginComparison(with: candidates)
    }

    func beginComparison(with urls: [URL]) {
        let candidates = Array(urls.prefix(2))
        guard candidates.count == 2 else {
            statusText = "比較する写真を2枚選択してください"
            return
        }
        comparisonURLs = candidates
        comparisonFrames = [:]
        zoomMode = .fit
        viewMode = .comparison
        gridSelection.removeAll(keepingCapacity: true)
        loadComparisonFrames(fullResolution: false)
    }

    /// A/Bの勝者を残し、表示順で次の候補との比較へ進む。
    func chooseComparisonWinner(slot: Int) {
        guard comparisonURLs.indices.contains(slot) else { return }
        let winner = comparisonURLs[slot]
        let visible = visibleFiles
        let furthestIndex = comparisonURLs.compactMap { visible.firstIndex(of: $0) }.max() ?? -1
        guard visible.indices.contains(furthestIndex + 1) else {
            statusText = "最後の候補です（勝者: \(winner.lastPathComponent)）"
            return
        }
        comparisonURLs = [winner, visible[furthestIndex + 1]]
        comparisonFrames = comparisonFrames.filter { $0.key == winner }
        statusText = ""
        loadComparisonFrames(fullResolution: zoomMode == .actualSize)
    }

    private func loadComparisonFrames(fullResolution: Bool) {
        let requestedURLs = comparisonURLs
        let targetPixels = displayTargetPixels
        let cache = cache
        for url in requestedURLs where comparisonFrames[url] == nil
            || (fullResolution && comparisonFrames[url]?.frame.isFullResolution != true)
        {
            Task { [weak self] in
                guard
                    let frame = try? await cache.value(
                        for: FrameKey(url: url, full: fullResolution),
                        loader: {
                            let cpu = try fullResolution
                                ? ImagePipeline.loadFullResolutionFrame(from: url)
                                : ImagePipeline.loadDisplayFrame(
                                    from: url, displayTarget: targetPixels)
                            return try TextureFactory.makeFrame(from: cpu)
                        })
                else { return }
                self?.installComparisonFrame(frame, for: url, expecting: requestedURLs)
            }
        }
    }

    private func installComparisonFrame(
        _ frame: TextureFrame, for url: URL, expecting urls: [URL]
    ) {
        guard viewMode == .comparison, comparisonURLs == urls else { return }
        generation += 1
        comparisonFrames[url] = PresentedFrame(generation: generation, frame: frame)
    }

    /// 表示中フレームがフル解像でなければ（M262のハーフサイズ）、
    /// フルデモザイクを遅延実行して差し替える
    private func ensureFullResolution() {
        guard let url = currentURL,
            let presented = currentFrame, !presented.frame.isFullResolution
        else { return }
        let requested = generation
        let cache = cache
        Task { [weak self] in
            guard
                let frame = try? await cache.value(for: FrameKey(url: url, full: true), loader: {
                    try Task.checkCancellation()
                    let cpu = try ImagePipeline.loadFullResolutionFrame(from: url)
                    return try TextureFactory.makeFrame(from: cpu)
                })
            else { return }
            self?.swapToFullResolution(frame, requested: requested)
        }
    }

    private func swapToFullResolution(_ frame: TextureFrame, requested: Int) {
        // 差し替え前にユーザーが移動/ズーム解除していたら破棄
        guard requested == generation, zoomMode == .actualSize else { return }
        generation += 1
        let presented = PresentedFrame(generation: generation, frame: frame)
        currentFrame = presented
        renderView?.show(presented)
    }

    /// レート/ラベルキーの処理。
    /// "1"-"5"=レート / "0"=クリア / "x"=除外トグル / "6"-"9"=カラーラベルトグル
    func handleRatingKey(_ characters: String) {
        let key = characters.lowercased()
        switch key {
        case "1", "2", "3", "4", "5":
            applyRating(Int(characters)!)
        case "0":
            applyRating(0)
        case "x":
            applyRating(-1)
        case "6", "7", "8", "9":
            if let label = ColorLabel.all.first(where: { $0.key == key })?.value {
                applyLabel(label)
            }
        default:
            break
        }
    }

    /// 同basename（=同一ショットのDNG+JPGペア）の全URL。
    /// サイドカーは basename.xmp をペアで共有するため、レート等のメモリ状態も
    /// ペアでまとめて更新する（片方だけ更新すると再起動後の復元結果とズレる）
    private func pairURLs(of url: URL) -> [URL] {
        LibrarySelection.pairedURLs(of: url, in: files)
    }

    private var metadataTargetURLs: [URL] {
        if viewMode == .grid, !gridSelection.isEmpty {
            return visibleFiles.filter { gridSelection.contains($0) }
        }
        return currentURL.map { [$0] } ?? []
    }

    private var metadataShotTargets: [(imageURL: URL, memberURLs: [URL])] {
        var seen = Set<URL>()
        return metadataTargetURLs.compactMap { url in
            let base = url.deletingPathExtension()
            guard seen.insert(base).inserted else { return nil }
            return (url, pairURLs(of: url))
        }
    }

    /// カラーラベルを適用（同じ色を再指定でトグル解除）してサイドカーへ書き込み
    private func applyLabel(_ label: String) {
        let targets = metadataShotTargets
        guard let url = targets.first?.imageURL else { return }
        let advanceDestination = targets.count == 1 ? nextURLForAutoAdvance() : nil
        let clear = targets.allSatisfy { labels[$0.imageURL] == label }
        let new: String? = clear ? nil : label
        let edits = targets.compactMap { target -> MetadataEdit? in
            let before = labels[target.imageURL]
            guard before != new else { return nil }
            return MetadataEdit(
                imageURL: target.imageURL, memberURLs: target.memberURLs,
                before: .label(before), after: .label(new))
        }
        applyNewMetadataTransaction(edits, focusURL: url)
        if targets.count == 1 { autoAdvance(from: url, to: advanceDestination) }
    }

    /// レートを適用してXMPサイドカーへ非同期書き込み。除外(-1)は再指定でトグル解除
    private func applyRating(_ rating: Int) {
        let targets = metadataShotTargets
        guard let url = targets.first?.imageURL else { return }
        let advanceDestination = targets.count == 1 ? nextURLForAutoAdvance() : nil
        let clearRejected = rating == -1 && targets.allSatisfy {
            (ratings[$0.imageURL] ?? 0) == -1
        }
        let new = clearRejected ? 0 : rating
        let edits = targets.compactMap { target -> MetadataEdit? in
            let before = ratings[target.imageURL] ?? 0
            guard before != new else { return nil }
            return MetadataEdit(
                imageURL: target.imageURL, memberURLs: target.memberURLs,
                before: .rating(before), after: .rating(new))
        }
        guard !edits.isEmpty else { return }
        applyNewMetadataTransaction(edits, focusURL: url)
        if targets.count == 1 { autoAdvance(from: url, to: advanceDestination) }
    }

    private func nextURLForAutoAdvance() -> URL? {
        let visible = visibleFiles
        guard visible.indices.contains(currentIndex + 1) else { return nil }
        return visible[currentIndex + 1]
    }

    private func autoAdvance(from source: URL, to destination: URL?) {
        guard autoAdvanceAfterRating else { return }
        guard let destination else {
            // 最後の写真では現在位置を維持する。変更でフィルター対象外になった場合も戻す。
            focus(on: source)
            return
        }
        let visible = visibleFiles
        if let index = visible.firstIndex(of: destination) {
            currentIndex = index
            if viewMode == .single { loadCurrent() }
        } else {
            focus(on: destination)
        }
    }

    private func nextXMPWriteRevision() -> UInt64 {
        xmpWriteRevision &+= 1
        return xmpWriteRevision
    }

    private func finishXMPWrite(revision: UInt64) {
        guard revision == xmpWriteRevision, statusText.hasPrefix("XMP書き込み失敗") else {
            return
        }
        statusText = ""
    }

    private func reportXMPError(_ error: any Error, for url: URL, revision: UInt64) {
        guard revision == xmpWriteRevision else { return }
        statusText = "XMP書き込み失敗 (\(url.lastPathComponent)): \(error)"
    }

    // MARK: - メタデータ Undo / Redo

    private func applyNewMetadataTransaction(_ edits: [MetadataEdit], focusURL: URL) {
        guard !edits.isEmpty else { return }
        for edit in edits {
            applyMetadataValue(edit.after, to: edit.memberURLs)
            writeMetadataValue(edit.after, for: edit.imageURL)
        }
        metadataHistory.record(MetadataTransaction(edits: edits, focusURL: focusURL))
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndoMetadata = metadataHistory.canUndo
        canRedoMetadata = metadataHistory.canRedo
    }

    func undoMetadata() {
        guard let transaction = metadataHistory.takeUndo() else { return }
        applyMetadataTransaction(transaction, useAfter: false)
        updateHistoryAvailability()
    }

    func redoMetadata() {
        guard let transaction = metadataHistory.takeRedo() else { return }
        applyMetadataTransaction(transaction, useAfter: true)
        updateHistoryAvailability()
    }

    private func applyMetadataTransaction(
        _ transaction: MetadataTransaction, useAfter: Bool
    ) {
        for edit in transaction.edits {
            let value = useAfter ? edit.after : edit.before
            applyMetadataValue(value, to: edit.memberURLs)
            writeMetadataValue(value, for: edit.imageURL)
        }
        if let focusURL = transaction.focusURL { focus(on: focusURL) }
    }

    private func applyMetadataValue(_ value: MetadataValue, to urls: [URL]) {
        switch value {
        case .rating(let rating):
            for url in urls { ratings[url] = rating }
        case .label(let label):
            for url in urls {
                if let label { labels[url] = label } else { labels.removeValue(forKey: url) }
            }
        case .keywords(let updated):
            for url in urls {
                if updated.isEmpty {
                    keywords.removeValue(forKey: url)
                } else {
                    keywords[url] = updated
                }
            }
        }
    }

    private func writeMetadataValue(_ value: MetadataValue, for url: URL) {
        let revision = nextXMPWriteRevision()
        let writer = xmpWriter
        Task(priority: .utility) { [weak self] in
            do {
                let applied: Bool
                switch value {
                case .rating(let rating):
                    applied = try await writer.writeRating(
                        rating, forImageAt: url, revision: revision,
                        createSidecarIfMissing: rating != 0)
                case .label(let label):
                    applied = try await writer.writeLabel(
                        label, forImageAt: url, revision: revision)
                case .keywords(let updated):
                    applied = try await writer.writeKeywords(
                        updated, forImageAt: url, revision: revision)
                }
                if applied { self?.finishXMPWrite(revision: revision) }
            } catch {
                self?.reportXMPError(error, for: url, revision: revision)
            }
        }
    }

    private func focus(on url: URL) {
        if !visibleFiles.contains(url) {
            var updated = filter
            updated.evaluation = .all
            filter = updated
        }
        if !visibleFiles.contains(url) {
            filter = FilterState()
        }
        let visible = visibleFiles
        guard let index = visible.firstIndex(of: url) ?? visible.firstIndex(where: {
            $0.deletingPathExtension() == url.deletingPathExtension()
        }) else { return }
        currentIndex = index
        if viewMode == .single { loadCurrent() }
    }

    // MARK: - エクスポート（⌘E）

    /// scope に該当するエクスポート対象。件数プレビューにも使う。
    /// 種別モードで隠れているファイルは対象にしない
    func exportURLs(for scope: ExportScope) -> [URL] {
        switch scope {
        case .visible:
            visibleFiles
        case .minRating(let n):
            typedFiles.filter { (ratings[$0] ?? 0) >= n }
        case .label(let wanted):
            typedFiles.filter { labels[$0] == wanted }
        case .keyword(let wanted):
            typedFiles.filter { keywords[$0]?.contains(wanted) ?? false }
        }
    }

    func beginExport() {
        guard !files.isEmpty, exportProgress == nil else { return }
        isExportSheetPresented = true
    }

    /// 書き出し先を選ばせてコピーを開始。同名ファイルは上書きせずスキップ
    func runExport(
        scope: ExportScope, includeSidecars: Bool, verifyChecksum: Bool
    ) {
        guard exportProgress == nil else { return }
        let sources = exportURLs(for: scope)
        guard !sources.isEmpty, let sourceRoot = currentFolder else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "書き出す"
        panel.message = "書き出し先フォルダを選択"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let plan = Exporter.makePlan(
            sources: sources,
            sourceRoot: sourceRoot,
            destination: destination,
            includeSidecars: includeSidecars)
        guard confirmExportConflicts(plan) else { return }

        exportProgress = ExportProgress(
            completed: 0, total: plan.items.count + plan.sidecars.count)
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            var result = ExportResult()
            var completed = 0
            var copiedImageSources = Set<URL>()
            for (index, item) in plan.items.enumerated() {
                if Task.isCancelled { break }
                let outcome = Exporter.copyImage(
                    item, verifyChecksum: verifyChecksum)
                result.recordImage(outcome)
                if outcome == .copied { copiedImageSources.insert(item.sourceImage) }
                completed = index + 1
                await self?.updateExportProgress(completed: completed)
            }
            if !Task.isCancelled {
                for sidecar in plan.sidecars {
                    if Task.isCancelled { break }
                    let shouldCopy = sidecar.relatedImageSources.contains {
                        copiedImageSources.contains($0)
                    }
                    let outcome = shouldCopy
                        ? Exporter.copySidecar(
                            sidecar, verifyChecksum: verifyChecksum)
                        : .notAttempted
                    result.recordSidecar(outcome)
                    completed += 1
                    await self?.updateExportProgress(completed: completed)
                }
            }
            await self?.finishExport(result, cancelled: Task.isCancelled)
        }
    }

    private func confirmExportConflicts(_ plan: ExportPlan) -> Bool {
        guard plan.conflictCount > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "書き出し先に同名ファイルがあります"
        alert.informativeText =
            "画像 \(plan.imageConflictCount)件、XMP \(plan.sidecarConflictCount)件は"
            + "上書きせずスキップします。"
        alert.addButton(withTitle: "既存ファイルを残して続行")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func updateExportProgress(completed: Int) {
        exportProgress?.completed = completed
    }

    private func finishExport(_ result: ExportResult, cancelled: Bool) {
        exportProgress = nil
        exportTask = nil
        isExportSheetPresented = false
        var parts = ["画像コピー \(result.imagesCopied)件"]
        if result.imagesSkipped > 0 {
            parts.append("画像スキップ \(result.imagesSkipped)件")
        }
        if result.imagesFailed > 0 { parts.append("画像失敗 \(result.imagesFailed)件") }
        if result.imagesVerificationFailed > 0 {
            parts.append("画像検証失敗 \(result.imagesVerificationFailed)件")
        }
        if result.sidecarsCopied > 0 { parts.append("XMPコピー \(result.sidecarsCopied)件") }
        if result.sidecarsSkipped > 0 {
            parts.append("XMPスキップ \(result.sidecarsSkipped)件")
        }
        if result.sidecarsFailed > 0 { parts.append("XMP失敗 \(result.sidecarsFailed)件") }
        if result.sidecarsNotAttempted > 0 {
            parts.append("XMP未実行 \(result.sidecarsNotAttempted)件")
        }
        if result.sidecarsVerificationFailed > 0 {
            parts.append("XMP検証失敗 \(result.sidecarsVerificationFailed)件")
        }
        statusText = (cancelled ? "書き出し中断: " : "書き出し完了: ") + parts.joined(separator: " / ")
    }

    // MARK: - 除外(✕)のゴミ箱移動

    var rejectedCount: Int {
        typedFiles.count(where: { ratings[$0] == -1 })
    }

    /// 除外を付けたファイルとそのXMPサイドカーをゴミ箱へ移動する（ゴミ箱から復元可能）。
    /// 元画像への「書き込み」はしないという不変条件は保ったまま、ファイル単位で移動する。
    /// 種別モードで隠れているファイルは対象にしない（見えていないものは消さない）
    func trashRejected() {
        let rejected = typedFiles.filter { ratings[$0] == -1 }
        guard !rejected.isEmpty else { return }
        let plan = LibraryOperations.trashPlan(rejectedURLs: rejected, allFiles: files)
        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var trashed: [URL] = []
            var failed = 0
            var sidecarFailed = 0
            for url in plan.imageURLs {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    trashed.append(url)
                } catch {
                    failed += 1
                }
            }
            // ペアの一部だけ移動に失敗した場合は、残った画像の共有XMPを保護する。
            let trashedSet = Set(trashed)
            for sidecar in plan.sidecarURLs {
                let base = sidecar.deletingPathExtension()
                let members = plan.imageURLs.filter {
                    $0.deletingPathExtension() == base
                }
                guard members.allSatisfy({ trashedSet.contains($0) }),
                    fm.fileExists(atPath: sidecar.path)
                else { continue }
                do {
                    try fm.trashItem(at: sidecar, resultingItemURL: nil)
                } catch {
                    sidecarFailed += 1
                }
            }
            await self?.removeTrashedFiles(
                trashed, failed: failed, sidecarFailed: sidecarFailed)
        }
    }

    private func removeTrashedFiles(
        _ trashed: [URL], failed: Int, sidecarFailed: Int
    ) {
        let removed = Set(trashed)
        let selected = currentURL
        files.removeAll { removed.contains($0) }
        for url in trashed {
            ratings.removeValue(forKey: url)
            labels.removeValue(forKey: url)
            keywords.removeValue(forKey: url)
        }
        let visible = visibleFiles
        if let selected, let index = visible.firstIndex(of: selected) {
            currentIndex = index
        } else {
            currentIndex = min(max(0, currentIndex), max(0, visible.count - 1))
            if visible.isEmpty {
                viewMode = .grid
                currentFrame = nil
            } else if viewMode == .single {
                loadCurrent()
            }
        }
        var details: [String] = []
        if failed > 0 { details.append("画像失敗 \(failed)件") }
        if sidecarFailed > 0 { details.append("XMP失敗 \(sidecarFailed)件") }
        statusText = "ゴミ箱へ移動: \(trashed.count)件"
        if !details.isEmpty { statusText += "（\(details.joined(separator: " / "))）" }
    }

    /// レンダラから present 完了が通知される。キー押下→表示のレイテンシ確定点。
    /// 古いフレームの再描画（SwiftUI更新等）は id 不一致で無視する。
    /// presentedTime は画面に実際に表示された時刻（コールバック配送遅延を含まない）
    func frameDidPresent(id: Int, presentedTime: CFTimeInterval) {
        guard id == generation, navigationStart != nil else { return }
        navigationStart = nil
        if let state = navigateState {
            signposter.endInterval("navigate", state)
            navigateState = nil
        }
        let totalMS = max(0, (presentedTime - navigationStartMedia) * 1000)
        latencyText = String(
            format: "%.0fms (app %.1fms / decode %.0fms)",
            totalMS, lastWorkMS, lastDecodeDuration.milliseconds)

        if isAutotest {
            advanceAutotest(totalMS: totalMS)
        }
    }

    private func loadCurrent() {
        let visible = visibleFiles
        guard visible.indices.contains(currentIndex) else { return }
        let url = visible[currentIndex]
        generation += 1
        let requested = generation
        navigationStart = ContinuousClock.now
        navigationStartMedia = CACurrentMediaTime()
        navigateState = signposter.beginInterval("navigate")

        let cache = cache
        let target = displayTargetPixels
        Task { [weak self] in
            let result: Result<TextureFrame, any Error>
            do {
                let frame = try await cache.value(for: FrameKey(url: url, full: false)) {
                    try Task.checkCancellation()
                    let cpu = try ImagePipeline.loadDisplayFrame(
                        from: url, displayTarget: target)
                    return try TextureFactory.makeFrame(from: cpu)
                }
                result = .success(frame)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.finishLoad(result, requested: requested)
            await self.schedulePrefetch()
        }

        // キャッシュミスなら埋め込みプレビューを速報表示（本デコード完了時に差し替え）。
        // JPGは埋め込みプレビューが極小サムネしかないため対象外
        guard !url.isJPEGFile else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard await cache.peek(FrameKey(url: url, full: false)) == nil,
                let cpu = try? ImagePipeline.loadProvisionalFrame(from: url),
                let frame = try? TextureFactory.makeFrame(from: cpu)
            else { return }
            await self?.presentProvisional(frame, requested: requested)
        }
    }

    /// ミス時の速報表示。本フレームが先に届いていたら何もしない。
    /// present は本フレームと同じ世代で行い、計測（frameDidPresent）は
    /// 「最初に何かが見えるまで」の時間を指すことになる
    private func presentProvisional(_ frame: TextureFrame, requested: Int) {
        guard requested == generation, realFrameGeneration != requested else { return }
        provisionalGeneration = requested
        lastDecodeDuration = frame.decodeDuration
        let presented = PresentedFrame(generation: requested, frame: frame)
        currentFrame = presented
        renderView?.show(presented)
        lastWorkMS = (CACurrentMediaTime() - navigationStartMedia) * 1000
    }

    private func finishLoad(_ result: Result<TextureFrame, any Error>, requested: Int) {
        // キー連打で古い結果が後から届いた場合は破棄
        guard requested == generation else { return }
        switch result {
        case .success(let frame):
            realFrameGeneration = requested
            lastDecodeDuration = frame.decodeDuration
            // 速報を出した後の差し替えは世代を進める
            // （MetalLayerView は同一世代の show をスキップするため）
            let presentGeneration: Int
            if provisionalGeneration == requested {
                generation += 1
                presentGeneration = generation
            } else {
                presentGeneration = requested
            }
            let presented = PresentedFrame(generation: presentGeneration, frame: frame)
            currentFrame = presented
            statusText = ""
            renderView?.show(presented)
            lastWorkMS = (CACurrentMediaTime() - navigationStartMedia) * 1000
            if let url = currentURL {
                storeHotFrame(frame, for: url)
            }
            if zoomMode == .actualSize {
                ensureFullResolution()
            }
        case .failure(let error):
            statusText = "読み込み失敗: \(error)"
        }
    }

    /// 進行方向の前方4枚・後方1枚を先読みし、対象外のプリフェッチはキャンセルする。
    /// 完了したフレームは MainActor 側のホットミラーにも載せる。
    /// M262はデコード250ms/枚だが画像間の並列は効くため、窓を広げてCPUを遊ばせない
    /// （ダウンサンプル後のテクスチャは1枚24〜32MBなのでメモリ影響は小さい）
    private func schedulePrefetch() async {
        let visible = visibleFiles
        guard !visible.isEmpty else { return }
        // 進行方向優先の順序で並べる（直近1枚 → 逆隣 → その先）
        let dir = lastNavigationDirection
        let candidates = [dir, -dir, 2 * dir, 3 * dir, 4 * dir]
            .map { currentIndex + $0 }
            .filter { visible.indices.contains($0) }
        let keep = Set(candidates.map { FrameKey(url: visible[$0], full: false) })
        await cache.cancelPrefetches(keeping: keep)
        trimHotFrames()
        let target = displayTargetPixels
        for index in candidates {
            let url = visible[index]
            let task = await cache.prefetch(key: FrameKey(url: url, full: false)) {
                try Task.checkCancellation()
                let cpu = try ImagePipeline.loadDisplayFrame(from: url, displayTarget: target)
                return try TextureFactory.makeFrame(from: cpu)
            }
            Task { [weak self] in
                // このTaskはMainActorを継承するため storeHotFrame は同期呼び出しでよい
                guard let frame = try? await task.value else { return }
                self?.storeHotFrame(frame, for: url)
            }
        }
    }

    private func storeHotFrame(_ frame: TextureFrame, for url: URL) {
        hotFrames[url] = frame
        trimHotFrames()
    }

    /// ホットミラーは現在位置 ±4 の窓（先読み窓と同幅）だけ保持する（実体はLRUキャッシュと共有）
    private func trimHotFrames() {
        let visible = visibleFiles
        let window = (currentIndex - 4) ... (currentIndex + 4)
        let allowed = Set(window.compactMap { visible.indices.contains($0) ? visible[$0] : nil })
        hotFrames = hotFrames.filter { allowed.contains($0.key) }
    }

    // MARK: - autotest

    private func advanceAutotest(totalMS: Double) {
        let ms = totalMS
        let label = autotestPhase == .forward ? "PASS1" : "PASS2"
        print(
            String(
                format: "%@\t%@\tglass %.1fms\tapp %.1fms\t(decode %.1fms)",
                label, fileNameText, ms, lastWorkMS, lastDecodeDuration.milliseconds))
        switch autotestPhase {
        case .forward:
            pass1Latencies.append(ms)
            // 終端は送り対象（visibleFiles）で判定する。files で判定すると
            // 種別モードで一部が隠れているとき終端に到達せずハングする
            if currentIndex + 1 < visibleFiles.count {
                navigate(1)
            } else {
                autotestPhase = .backward
                navigate(-1)
            }
        case .backward:
            pass2Latencies.append(ms)
            if currentIndex > 0 {
                navigate(-1)
            } else {
                finishAutotest()
            }
        }
    }

    private func finishAutotest() {
        func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let average = values.reduce(0, +) / Double(values.count)
            return String(
                format: "n=%d avg %.1fms / min %.1fms / max %.1fms",
                values.count, average, values.min() ?? 0, values.max() ?? 0)
        }
        print("PASS1(往路・先読み効果込み): " + summary(pass1Latencies))
        print("PASS2(復路・全ヒット想定): " + summary(pass2Latencies))
        let cache = cache
        Task { @MainActor in
            let stats = await cache.currentStats()
            print(
                "cache: hits=\(stats.hits) misses=\(stats.misses)"
                    + " evictions=\(stats.evictions)"
                    + " bytes=\(stats.totalBytes / 1_048_576)MB")
            NSApplication.shared.terminate(nil)
        }
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
