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

    /// フィルター適用後の表示・送り対象。グリッドとナビゲーションはこちらを使う
    var visibleFiles: [URL] {
        guard filter.isActive else { return files }
        return files.filter { passesFilter($0) }
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
        return filter.isActive ? base + " (全\(files.count))" : base
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
        if parsed.isEmpty {
            keywords.removeValue(forKey: url)
        } else {
            keywords[url] = parsed
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
        let visible = visibleFiles
        if let selected, let index = visible.firstIndex(of: selected) {
            currentIndex = index
        } else {
            currentIndex = min(max(0, currentIndex), max(0, visible.count - 1))
            if viewMode == .single {
                if visible.isEmpty {
                    viewMode = .grid
                } else {
                    loadCurrent()
                }
            }
        }
    }

    /// グリッドのサムネイル供給（LRU 320MB）
    @ObservationIgnored let thumbnails = ThumbnailProvider()

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

        let arguments = CommandLine.arguments
        isAutotest = arguments.contains("--autotest")
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
            let found = Self.findDNGs(in: url)
            await self?.applyFolderContents(found, for: url)
        }
    }

    /// 再帰的にDNGを列挙（隠しファイル・パッケージ内は除外、上限1万件）
    private nonisolated static func findDNGs(in root: URL) -> [URL] {
        var result: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension.uppercased() == "DNG" {
                result.append(item)
                if result.count >= 10_000 { break }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func applyFolderContents(_ found: [URL], for url: URL) {
        guard currentFolder == url else { return } // 列挙中に別フォルダへ移動した
        files = found
        statusText = files.isEmpty ? "DNGが見つかりません" : ""
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

    /// カラーラベルを適用（同じ色を再指定でトグル解除）してサイドカーへ書き込み
    private func applyLabel(_ label: String) {
        guard let url = currentURL else { return }
        let new: String? = labels[url] == label ? nil : label
        if let new {
            labels[url] = new
        } else {
            labels.removeValue(forKey: url)
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
        ratings[url] = new

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
    }

    private func finishLoad(_ result: Result<TextureFrame, any Error>, requested: Int) {
        // キー連打で古い結果が後から届いた場合は破棄
        guard requested == generation else { return }
        switch result {
        case .success(let frame):
            lastDecodeDuration = frame.decodeDuration
            let presented = PresentedFrame(generation: requested, frame: frame)
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
            if currentIndex + 1 < files.count {
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
