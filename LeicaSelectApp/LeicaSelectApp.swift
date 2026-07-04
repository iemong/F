import SwiftUI

@main
struct LeicaSelectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("フォルダを開く…") {
                    model.openFolder()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    let model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.viewMode {
            case .grid:
                if model.files.isEmpty {
                    emptyState
                } else {
                    GridView(model: model)
                }
            case .single:
                if let presented = model.currentFrame {
                    MetalImageView(
                        presented: presented,
                        zoomMode: model.zoomMode,
                        onPresent: { id, time in model.frameDidPresent(id: id, presentedTime: time) },
                        register: { view in model.registerRenderView(view) }
                    )
                    .ignoresSafeArea()
                } else {
                    emptyState
                }
            }

            VStack {
                Spacer()
                HStack {
                    statusBar
                    Spacer()
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) {
            model.navigate(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.navigate(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveSelectionVertically(-1)
            return model.viewMode == .grid ? .handled : .ignored
        }
        .onKeyPress(.downArrow) {
            model.moveSelectionVertically(1)
            return model.viewMode == .grid ? .handled : .ignored
        }
        .onKeyPress(.return) {
            guard model.viewMode == .grid else { return .ignored }
            model.openSelected()
            return .handled
        }
        .onKeyPress(.space) {
            switch model.viewMode {
            case .grid: model.openSelected()
            case .single: model.toggleZoom()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            guard model.viewMode == .single else { return .ignored }
            model.showGrid()
            return .handled
        }
        .onKeyPress(keys: ["z"]) { _ in
            model.toggleZoom()
            return .handled
        }
        .onKeyPress(keys: ["g"]) { _ in
            switch model.viewMode {
            case .single: model.showGrid()
            case .grid: model.openSelected()
            }
            return .handled
        }
        .onKeyPress(keys: ["1", "2", "3", "4", "5", "0", "x"]) { press in
            model.handleRatingKey(press.characters)
            return .handled
        }
        .onAppear {
            isFocused = true
            model.bootstrap()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("⌘O でDNGのあるフォルダを開く")
                .foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if !model.positionText.isEmpty {
                Text(model.positionText)
            }
            if model.viewMode == .grid {
                if let url = model.currentURL {
                    Text(url.lastPathComponent)
                }
            } else if !model.fileNameText.isEmpty {
                Text(model.fileNameText)
            }
            if !model.ratingText.isEmpty {
                Text(model.ratingText)
                    .foregroundStyle(model.ratingText.hasPrefix("✕") ? .red : .yellow)
            }
            if !model.zoomText.isEmpty {
                Text(model.zoomText)
                    .foregroundStyle(.cyan)
            }
            if model.viewMode == .single, !model.latencyText.isEmpty {
                Text(model.latencyText)
                    .foregroundStyle(.green)
            }
            if !model.statusText.isEmpty {
                Text(model.statusText)
                    .foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }
}
