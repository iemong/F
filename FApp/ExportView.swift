import SwiftUI

/// ⌘E で開くエクスポートシート。対象（表示中/レート/ラベル/キーワード）を選び、
/// DNG＋XMPサイドカーを別フォルダへコピーする
struct ExportView: View {
    @Bindable var model: AppModel

    private enum ScopeChoice: Hashable {
        case visible, rating, label, keyword
    }

    @State private var choice: ScopeChoice = .visible
    @State private var minRating = 3
    @State private var selectedLabel = "Red"
    @State private var selectedKeyword = ""
    @State private var includeSidecars = true

    private var scope: ExportScope {
        switch choice {
        case .visible: .visible
        case .rating: .minRating(minRating)
        case .label: .label(selectedLabel)
        case .keyword: .keyword(selectedKeyword)
        }
    }

    private var targetCount: Int {
        model.exportURLs(for: scope).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("書き出し")
                .font(.headline)

            if let progress = model.exportProgress {
                exportingBody(progress)
            } else {
                settingsBody
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            if let first = model.allFolderKeywords.first {
                selectedKeyword = first
            }
        }
    }

    private func exportingBody(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(
                value: Double(progress.completed),
                total: Double(max(1, progress.total))
            ) {
                Text("コピー中… \(progress.completed)/\(progress.total)")
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Spacer()
                Button("中断") { model.cancelExport() }
            }
        }
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("対象", selection: $choice) {
                Text("表示中のファイル").tag(ScopeChoice.visible)
                Text("レートで絞る").tag(ScopeChoice.rating)
                Text("カラーラベルで絞る").tag(ScopeChoice.label)
                if !model.allFolderKeywords.isEmpty {
                    Text("キーワードで絞る").tag(ScopeChoice.keyword)
                }
            }
            .pickerStyle(.radioGroup)

            switch choice {
            case .visible:
                EmptyView()
            case .rating:
                Picker("レート", selection: $minRating) {
                    ForEach(1 ..< 6) { n in
                        Text("★\(n) 以上").tag(n)
                    }
                }
                .frame(width: 200)
            case .label:
                Picker("ラベル", selection: $selectedLabel) {
                    ForEach(ColorLabel.all, id: \.value) { item in
                        Text("● \(LabelColorStyle.displayName(item.value))").tag(item.value)
                    }
                }
                .frame(width: 200)
            case .keyword:
                Picker("キーワード", selection: $selectedKeyword) {
                    ForEach(model.allFolderKeywords, id: \.self) { keyword in
                        Text("#\(keyword)").tag(keyword)
                    }
                }
                .frame(width: 200)
            }

            Toggle("XMPサイドカーも一緒にコピー（レート/ラベル/キーワードを引き継ぐ）", isOn: $includeSidecars)

            Text("対象: \(targetCount)件（同名ファイルは上書きせずスキップ）")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("キャンセル") { model.isExportSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("書き出し先を選んで開始…") {
                    model.runExport(scope: scope, includeSidecars: includeSidecars)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targetCount == 0)
            }
        }
    }
}
