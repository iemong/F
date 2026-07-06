import AppKit
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

/// グリッド/送り対象の絞り込み条件
struct FilterState: Equatable {
    /// 0 = 無効。1-5 = そのレート以上のみ（除外(-1)も落ちる）
    var minRating = 0
    var hideRejected = false
    /// 特定カラーラベルのみ（nil = 無効）
    var label: String?
    /// 特定キーワードを含むもののみ（nil = 無効）
    var keyword: String?

    var isActive: Bool { minRating > 0 || hideRejected || label != nil || keyword != nil }
}

/// カラーラベル（Lightroom互換のxmp:Label値とキー割当 6-9）
enum ColorLabel {
    static let all: [(key: String, value: String)] = [
        ("6", "Red"), ("7", "Yellow"), ("8", "Green"), ("9", "Blue"),
    ]
}

/// 表示するファイル種別（ツールバーで切替、UserDefaultsに永続化）。
/// DNG+JPG同時記録のフォルダで片方だけを見たいケースに応える
enum FileTypeMode: String, CaseIterable {
    case dng
    case jpg
    case both

    var displayName: String {
        switch self {
        case .dng: "DNG"
        case .jpg: "JPG"
        case .both: "両方"
        }
    }

    func matches(_ url: URL) -> Bool {
        switch self {
        case .dng: !url.isJPEGFile
        case .jpg: url.isJPEGFile
        case .both: true
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

    /// ファイル種別モード適用後の全ファイル。「全n件」表示やエクスポート対象の基底
    var typedFiles: [URL] {
        fileTypeMode == .both ? files : files.filter { fileTypeMode.matches($0) }
    }

    /// 種別モード+フィルター適用後の表示・送り対象。グリッドとナビゲーションはこちらを使う
    var visibleFiles: [URL] {
        let base = typedFiles
        guard filter.isActive else { return base }
        return base.filter { passesFilter($0) }
    }

    private func passesFilter(_ url: URL) -> Bool {
        let rating = ratings[url] ?? 0
        if filter.hideRejected, rating == -1 { return false }
        if filter.minRating > 0, rating < filter.minRating { return false }
        if let wanted = filter.label, labels[url] != wanted { return false }
        if let wanted = filter.keyword, !(keywords[url]?.contains(wanted) ?? false) {
            return false
        }
        return true
    }

    var positionText: String {
        let visible = visibleFiles
        guard !visible.isEmpty || filter.isActive else { return "" }
        let base = visible.isEmpty ? "0/0" : "\(currentIndex + 1)/\(visible.count)"
        return filter.isActive ? base + " (全\(typedFiles.count))" : base
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
        guard let url = currentURL else { return }
        keywordDraft = (keywords[url] ?? []).joined(separator: ", ")
        isEditingKeywords = true
    }

    func commitKeywordEditing() {
        defer { isEditingKeywords = false }
        guard let url = currentURL else { return }
        var seen = Set<String>()
        let parsed = keywordDraft
            .split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        for member in pairURLs(of: url) {
            if parsed.isEmpty {
                keywords.removeValue(forKey: member)
            } else {
                keywords[member] = parsed
            }
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                try XMPSidecar.writeKeywords(parsed, forImageAt: url)
            } catch {
                await self?.reportRatingError(error, for: url)
            }
        }
    }

    func cancelKeywordEditing() {
        isEditingKeywords = false
    }

    /// フィルター変更。選択中のファイルが残っていれば選択を維持する
    func setFilter(_ newFilter: FilterState) {
        guard newFilter != filter else { return }
        let selected = currentURL
        filter = newFilter
        reselect(previous: selected)
    }

    /// ファイル種別モードの切替。選択中のファイルが消える場合は
    /// 同basenameのペア相手（DNG⇔JPG）へ選択を引き継ぐ
    func setFileTypeMode(_ mode: FileTypeMode) {
        guard mode != fileTypeMode else { return }
        let selected = currentURL
        fileTypeMode = mode
        reselect(previous: selected)
    }

    /// 表示対象リストが変わった後（フィルター/種別切替）の選択位置の整合
    private func reselect(previous selected: URL?) {
        let visible = visibleFiles
        if let selected {
            if let index = visible.firstIndex(of: selected) {
                currentIndex = index
                return
            }
            // 同一ショットのペア相手（同basename）が残っていればそちらへ
            let base = selected.deletingPathExtension()
            if let index = visible.firstIndex(where: { $0.deletingPathExtension() == base }) {
                currentIndex = index
                if viewMode == .single { loadCurrent() }
                return
            }
        }
        currentIndex = min(max(0, currentIndex), max(0, visible.count - 1))
        if viewMode == .single {
            if visible.isEmpty {
                viewMode = .grid
            } else {
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

    func registerRenderView(_ view: MetalLayerView) {
        renderView = view
    }

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
        zoomMode = .fit
        statusText = "読み込み中…"

        // SDカードは DCIM/100LEICA/ のようにサブフォルダに入るため再帰で探す。
        // 大きいツリーやUSB越しでも固まらないよう列挙はバックグラウンド
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Self.findImages(in: url)
            await self?.applyFolderContents(found, for: url)
        }
    }

    /// 再帰的にDNG/JPGを列挙（隠しファイル・パッケージ内は除外、上限1万件）。
    /// 種別の絞り込みは列挙ではなく表示側（typedFiles）で行い、切替時の再走査を不要にする
    private nonisolated static func findImages(in root: URL) -> [URL] {
        let wanted: Set<String> = ["DNG", "JPG", "JPEG"]
        var result: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let item = enumerator?.nextObject() as? URL {
            if wanted.contains(item.pathExtension.uppercased()) {
                result.append(item)
                if result.count >= 10_000 { break }
            }
        }
        return result.sorted { $0.path < $1.path }
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

    func navigate(_ delta: Int) {
        let visible = visibleFiles
        guard !visible.isEmpty else { return }
        let newIndex = min(max(currentIndex + delta, 0), visible.count - 1)
        guard newIndex != currentIndex else { return }
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

    /// フィルムストリップ等からの任意位置ジャンプ。
    /// 隣接位置ならホットミラーの高速経路がそのまま効く
    func jumpTo(_ index: Int) {
        guard visibleFiles.indices.contains(index) else { return }
        navigate(index - currentIndex)
    }

    /// グリッド: 上下キーで1行分移動
    func moveSelectionVertically(_ rows: Int) {
        guard viewMode == .grid, !visibleFiles.isEmpty else { return }
        let newIndex = min(max(currentIndex + rows * gridColumns, 0), visibleFiles.count - 1)
        currentIndex = newIndex
    }

    func select(_ index: Int) {
        guard visibleFiles.indices.contains(index) else { return }
        currentIndex = index
    }

    /// グリッドから1枚表示へ
    func openSelected() {
        guard !visibleFiles.isEmpty else { return }
        viewMode = .single
        loadCurrent()
    }

    /// 1枚表示からグリッドへ
    func showGrid() {
        guard viewMode == .single else { return }
        viewMode = .grid
        zoomMode = .fit
    }

    /// Z / Space（1枚表示時）: fit ⇔ 100%等倍
    func toggleZoom() {
        guard viewMode == .single else { return }
        zoomMode = zoomMode == .fit ? .actualSize : .fit
        renderView?.setZoomMode(zoomMode)
        if zoomMode == .actualSize {
            ensureFullResolution()
        }
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
        let base = url.deletingPathExtension()
        return files.filter { $0.deletingPathExtension() == base }
    }

    /// カラーラベルを適用（同じ色を再指定でトグル解除）してサイドカーへ書き込み
    private func applyLabel(_ label: String) {
        guard let url = currentURL else { return }
        let new: String? = labels[url] == label ? nil : label
        for member in pairURLs(of: url) {
            if let new {
                labels[member] = new
            } else {
                labels.removeValue(forKey: member)
            }
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                try XMPSidecar.writeLabel(new, forImageAt: url)
            } catch {
                await self?.reportRatingError(error, for: url)
            }
        }
    }

    /// レートを適用してXMPサイドカーへ非同期書き込み。除外(-1)は再指定でトグル解除
    private func applyRating(_ rating: Int) {
        guard let url = currentURL else { return }
        let current = ratings[url] ?? 0
        let new = (rating == -1 && current == -1) ? 0 : rating
        guard new != current else { return }
        for member in pairURLs(of: url) {
            ratings[member] = new
        }

        // クリアかつサイドカー未作成なら、わざわざファイルを作らない
        if new == 0, !FileManager.default.fileExists(atPath: XMPSidecar.url(for: url).path) {
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                try XMPSidecar.writeRating(new, forImageAt: url)
            } catch {
                await self?.reportRatingError(error, for: url)
            }
        }
    }

    private func reportRatingError(_ error: any Error, for url: URL) {
        statusText = "XMP書き込み失敗 (\(url.lastPathComponent)): \(error)"
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
    func runExport(scope: ExportScope, includeSidecars: Bool) {
        guard exportProgress == nil else { return }
        let sources = exportURLs(for: scope)
        guard !sources.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "書き出す"
        panel.message = "書き出し先フォルダを選択"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        exportProgress = ExportProgress(completed: 0, total: sources.count)
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            var result = ExportResult()
            for (index, url) in sources.enumerated() {
                if Task.isCancelled { break }
                switch Exporter.copyItem(
                    at: url, into: destination, includeSidecar: includeSidecars)
                {
                case .copied: result.copied += 1
                case .skippedExisting: result.skipped += 1
                case .failed: result.failed += 1
                }
                await self?.updateExportProgress(completed: index + 1)
            }
            await self?.finishExport(result, cancelled: Task.isCancelled)
        }
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
        var parts = ["コピー \(result.copied)件"]
        if result.skipped > 0 { parts.append("同名スキップ \(result.skipped)件") }
        if result.failed > 0 { parts.append("失敗 \(result.failed)件") }
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
        // 共有サイドカー（basename.xmp）は、ペア相手（DNG⇔JPG）が1つでも残るなら
        // 残す。捨てられる側と一緒に消すと残った側のレート等が失われるため
        let rejectedSet = Set(rejected)
        let trashableSidecars = Set(
            rejected
                .filter { url in pairURLs(of: url).allSatisfy { rejectedSet.contains($0) } }
                .map { XMPSidecar.url(for: $0) })
        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var trashed: [URL] = []
            var failed = 0
            for url in rejected {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    let sidecar = XMPSidecar.url(for: url)
                    if trashableSidecars.contains(sidecar),
                        fm.fileExists(atPath: sidecar.path)
                    {
                        try? fm.trashItem(at: sidecar, resultingItemURL: nil)
                    }
                    trashed.append(url)
                } catch {
                    failed += 1
                }
            }
            await self?.removeTrashedFiles(trashed, failed: failed)
        }
    }

    private func removeTrashedFiles(_ trashed: [URL], failed: Int) {
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
        statusText =
            failed > 0
            ? "ゴミ箱へ移動: \(trashed.count)件（失敗 \(failed)件）"
            : "ゴミ箱へ移動: \(trashed.count)件"
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
        Task { [weak self] in
            let result: Result<TextureFrame, any Error>
            do {
                let frame = try await cache.value(for: FrameKey(url: url, full: false)) {
                    try Task.checkCancellation()
                    let cpu = try ImagePipeline.loadDisplayFrame(from: url)
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

    /// 前方2枚・後方1枚を先読みし、対象外のプリフェッチはキャンセルする。
    /// 完了したフレームは MainActor 側のホットミラーにも載せる
    private func schedulePrefetch() async {
        let visible = visibleFiles
        guard !visible.isEmpty else { return }
        // 前方優先の順序で並べる
        let candidates = [currentIndex + 1, currentIndex - 1, currentIndex + 2]
            .filter { visible.indices.contains($0) }
        let keep = Set(candidates.map { FrameKey(url: visible[$0], full: false) })
        await cache.cancelPrefetches(keeping: keep)
        trimHotFrames()
        for index in candidates {
            let url = visible[index]
            let task = await cache.prefetch(key: FrameKey(url: url, full: false)) {
                try Task.checkCancellation()
                let cpu = try ImagePipeline.loadDisplayFrame(from: url)
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

    /// ホットミラーは現在位置 ±2 の窓だけ保持する（実体はLRUキャッシュと共有）
    private func trimHotFrames() {
        let visible = visibleFiles
        let window = (currentIndex - 2) ... (currentIndex + 2)
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
