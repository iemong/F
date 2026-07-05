import SwiftUI

@main
struct FApp: App {
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

                Menu("最近使ったフォルダ") {
                    ForEach(model.recentFolders, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            model.openFolder(at: url)
                        }
                    }
                }
                .disabled(model.recentFolders.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Toggle(
                    "撮影情報を表示",
                    isOn: Binding(
                        get: { model.showInfoPanel },
                        set: { model.showInfoPanel = $0 })
                )
                .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("サムネイルを拡大") {
                    model.gridCellSize = min(400, model.gridCellSize + 40)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("サムネイルを縮小") {
                    model.gridCellSize = max(120, model.gridCellSize - 40)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
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

            if model.showInfoPanel, let url = model.currentURL {
                VStack {
                    HStack {
                        Spacer()
                        InfoPanelView(url: url, provider: model.captureInfoProvider)
                    }
                    Spacer()
                }
                .padding(12)
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
        .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "x"]) { press in
            model.handleRatingKey(press.characters)
            return .handled
        }
        .onKeyPress(keys: ["t"]) { _ in
            model.beginKeywordEditing()
            return .handled
        }
        .onKeyPress(keys: ["i"]) { _ in
            model.showInfoPanel.toggle()
            return .handled
        }
        .sheet(isPresented: $model.isEditingKeywords) {
            KeywordEditorView(model: model)
        }
        .onAppear {
            isFocused = true
            model.bootstrap()
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.positionText)
        .toolbar {
            ToolbarItem {
                Button {
                    model.openFolder()
                } label: {
                    Label("フォルダを開く", systemImage: "folder")
                }
                .help("フォルダを開く (⌘O)")
            }
            ToolbarItem {
                Menu {
                    if model.removableVolumes.isEmpty {
                        Text("外部ボリュームなし")
                    }
                    ForEach(model.removableVolumes) { volume in
                        Button(volume.name) {
                            model.openVolume(volume)
                        }
                    }
                } label: {
                    Label("SDカード", systemImage: "sdcard")
                }
                .help("SDカード / 外部ボリュームを開く")
            }
            ToolbarItem {
                filterMenu
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(
                "レート",
                selection: Binding(
                    get: { model.filter.minRating },
                    set: { value in
                        var updated = model.filter
                        updated.minRating = value
                        model.setFilter(updated)
                    })
            ) {
                Text("すべて").tag(0)
                ForEach(1 ..< 6) { n in
                    Text("★\(n) 以上").tag(n)
                }
            }
            Toggle(
                "除外(✕)を隠す",
                isOn: Binding(
                    get: { model.filter.hideRejected },
                    set: { value in
                        var updated = model.filter
                        updated.hideRejected = value
                        model.setFilter(updated)
                    }))
            Picker(
                "ラベル",
                selection: Binding(
                    get: { model.filter.label },
                    set: { value in
                        var updated = model.filter
                        updated.label = value
                        model.setFilter(updated)
                    })
            ) {
                Text("すべて").tag(String?.none)
                ForEach(ColorLabel.all, id: \.value) { item in
                    Text("● \(LabelColorStyle.displayName(item.value)) (\(item.key))")
                        .tag(String?.some(item.value))
                }
            }
            if !model.allFolderKeywords.isEmpty {
                Picker(
                    "キーワード",
                    selection: Binding(
                        get: { model.filter.keyword },
                        set: { value in
                            var updated = model.filter
                            updated.keyword = value
                            model.setFilter(updated)
                        })
                ) {
                    Text("すべて").tag(String?.none)
                    ForEach(model.allFolderKeywords, id: \.self) { keyword in
                        Text("#\(keyword)").tag(String?.some(keyword))
                    }
                }
            }
            if model.filter.isActive {
                Divider()
                Button("フィルター解除") {
                    model.setFilter(FilterState())
                }
            }
        } label: {
            Label(
                "フィルター",
                systemImage: model.filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .help("レート・ラベルで絞り込み")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Button("フォルダを開く…") {
                model.openFolder()
            }
            if !model.recentFolders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.recentFolders, id: \.self) { url in
                        Button {
                            model.openFolder(at: url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "clock")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
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
            if let label = model.currentLabel {
                Circle()
                    .fill(LabelColorStyle.color(label))
                    .frame(width: 9, height: 9)
            }
            if !model.currentKeywords.isEmpty {
                Text(model.currentKeywords.map { "#\($0)" }.joined(separator: " "))
                    .foregroundStyle(.cyan.opacity(0.9))
                    .lineLimit(1)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassPanel(cornerRadius: 10)
        .padding(12)
    }
}
