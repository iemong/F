import AppKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class AppModel {
    private(set) var files: [URL] = []
    private(set) var currentIndex = 0
    private(set) var currentFrame: DisplayFrame?
    private(set) var statusText = ""
    private(set) var latencyText = ""

    var positionText: String {
        files.isEmpty ? "" : "\(currentIndex + 1)/\(files.count)"
    }

    var fileNameText: String {
        currentFrame?.fileName ?? ""
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var navigationStart: ContinuousClock.Instant?
    @ObservationIgnored private var lastDecodeDuration: Duration = .zero
    @ObservationIgnored private let signposter = OSSignposter(
        subsystem: "LeicaSelect.App", category: "navigation")
    @ObservationIgnored private var navigateState: OSSignpostIntervalState?

    @ObservationIgnored private var isAutotest = false
    @ObservationIgnored private var autotestLatencies: [Double] = []

    /// @State の初期値式は nonisolated コンテキストで評価されるため
    nonisolated init() {}

    /// 起動引数の処理（開発・検証用）:
    /// --folder <path>  起動時にそのフォルダを開く（NSOpenPanel省略）
    /// --autotest       全ファイルを自動送りしてレイテンシを標準出力へ、完了後に終了
    func bootstrap() {
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

    private func loadFolder(_ url: URL) {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) ?? []
        files = contents
            .filter { $0.pathExtension.uppercased() == "DNG" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        currentIndex = 0
        currentFrame = nil
        statusText = files.isEmpty ? "DNGが見つかりません" : ""
        latencyText = ""
        if !files.isEmpty {
            loadCurrent()
        }
    }

    func navigate(_ delta: Int) {
        guard !files.isEmpty else { return }
        let newIndex = min(max(currentIndex + delta, 0), files.count - 1)
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
        loadCurrent()
    }

    /// レンダラから present 完了が通知される。キー押下→表示のレイテンシ確定点。
    /// 古いフレームの再描画（SwiftUI更新等）は id 不一致で無視する
    func frameDidPresent(id: Int) {
        guard id == generation, let start = navigationStart else { return }
        navigationStart = nil
        if let state = navigateState {
            signposter.endInterval("navigate", state)
            navigateState = nil
        }
        let total = ContinuousClock.now - start
        latencyText = String(
            format: "%.0fms (decode %.0fms)",
            total.milliseconds, lastDecodeDuration.milliseconds)

        if isAutotest {
            advanceAutotest(total: total)
        }
    }

    private func advanceAutotest(total: Duration) {
        autotestLatencies.append(total.milliseconds)
        print(
            String(
                format: "%@\t%.1fms\t(decode %.1fms)",
                fileNameText, total.milliseconds, lastDecodeDuration.milliseconds))
        if currentIndex + 1 < files.count {
            navigate(1)
        } else {
            let average = autotestLatencies.reduce(0, +) / Double(autotestLatencies.count)
            let worst = autotestLatencies.max() ?? 0
            print(
                String(
                    format: "autotest done: %d files, avg %.1fms, max %.1fms",
                    autotestLatencies.count, average, worst))
            NSApplication.shared.terminate(nil)
        }
    }

    private func loadCurrent() {
        guard files.indices.contains(currentIndex) else { return }
        let url = files[currentIndex]
        generation += 1
        let requested = generation
        navigationStart = ContinuousClock.now
        navigateState = signposter.beginInterval("navigate")

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<DisplayFrame, any Error>
            do {
                result = .success(try ImagePipeline.loadDisplayFrame(from: url, id: requested))
            } catch {
                result = .failure(error)
            }
            await self?.finishLoad(result, requested: requested)
        }
    }

    private func finishLoad(_ result: Result<DisplayFrame, any Error>, requested: Int) {
        // キー連打で古い結果が後から届いた場合は破棄
        guard requested == generation else { return }
        switch result {
        case .success(let frame):
            lastDecodeDuration = frame.decodeDuration
            currentFrame = frame
            statusText = ""
        case .failure(let error):
            statusText = "読み込み失敗: \(error)"
        }
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
