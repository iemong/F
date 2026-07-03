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

            if let presented = model.currentFrame {
                MetalImageView(
                    presented: presented,
                    onPresent: { id, time in model.frameDidPresent(id: id, presentedTime: time) },
                    register: { view in model.registerRenderView(view) }
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("⌘O でDNGのあるフォルダを開く")
                        .foregroundStyle(.secondary)
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
        .onAppear {
            isFocused = true
            model.bootstrap()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if !model.positionText.isEmpty {
                Text(model.positionText)
            }
            if !model.fileNameText.isEmpty {
                Text(model.fileNameText)
            }
            if !model.latencyText.isEmpty {
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
