import SwiftUI

struct ShortcutHint: Identifiable {
    let key: String
    let action: String

    var id: String { key + action }
}

enum ShortcutGuide {
    static func primaryHints(
        mode: ViewMode, hasFiles: Bool, hasMultipleSelection: Bool
    ) -> [ShortcutHint] {
        guard hasFiles else {
            return [
                ShortcutHint(key: "⌘O", action: "フォルダを開く"),
                ShortcutHint(key: "?", action: "ヘルプ"),
            ]
        }
        if mode == .grid, hasMultipleSelection {
            return [
                ShortcutHint(key: "⌘ / ⇧ Click", action: "選択を変更"),
                ShortcutHint(key: "1–5", action: "一括レート"),
                ShortcutHint(key: "X", action: "一括除外"),
                ShortcutHint(key: "6–9", action: "一括ラベル"),
                ShortcutHint(key: "T", action: "一括キーワード"),
                ShortcutHint(key: "?", action: "ヘルプ"),
            ]
        }
        switch mode {
        case .grid:
            return [
                ShortcutHint(key: "←→↑↓", action: "移動"),
                ShortcutHint(key: "↩ / Space", action: "開く"),
                ShortcutHint(key: "1–5", action: "レート"),
                ShortcutHint(key: "X", action: "除外"),
                ShortcutHint(key: "U", action: "次の未評価"),
                ShortcutHint(key: "?", action: "ヘルプ"),
            ]
        case .single:
            return [
                ShortcutHint(key: "←→", action: "移動"),
                ShortcutHint(key: "1–5", action: "レート"),
                ShortcutHint(key: "X", action: "除外"),
                ShortcutHint(key: "Z", action: "等倍"),
                ShortcutHint(key: "G", action: "グリッド"),
                ShortcutHint(key: "U", action: "次の未評価"),
                ShortcutHint(key: "?", action: "ヘルプ"),
            ]
        case .comparison:
            return [
                ShortcutHint(key: "A / B", action: "勝者を選択"),
                ShortcutHint(key: "Z", action: "同期等倍"),
                ShortcutHint(key: "Drag", action: "同期パン"),
                ShortcutHint(key: "G / Esc", action: "グリッド"),
                ShortcutHint(key: "?", action: "ヘルプ"),
            ]
        }
    }

    static let sections: [(title: String, hints: [ShortcutHint])] = [
        ("移動と表示", [
            ShortcutHint(key: "← →", action: "前後の写真へ移動"),
            ShortcutHint(key: "↑ ↓", action: "グリッドで行を移動"),
            ShortcutHint(key: "Return / Space", action: "選択した写真を開く"),
            ShortcutHint(key: "G / Esc", action: "グリッドに戻る"),
            ShortcutHint(key: "Z / Space", action: "1枚表示で等倍を切替"),
            ShortcutHint(key: "⌘ / ⇧ Click", action: "グリッドで個別 / 範囲選択"),
            ShortcutHint(key: "C", action: "選択した2枚を比較"),
            ShortcutHint(key: "A / B", action: "比較中の勝者を選択"),
        ]),
        ("評価", [
            ShortcutHint(key: "1–5", action: "レートを設定"),
            ShortcutHint(key: "0", action: "レートを解除"),
            ShortcutHint(key: "X", action: "除外を切替"),
            ShortcutHint(key: "6–9", action: "カラーラベルを切替"),
            ShortcutHint(key: "T", action: "キーワードを編集"),
            ShortcutHint(key: "U", action: "次の未評価へ移動"),
            ShortcutHint(key: "⌘Z / ⇧⌘Z", action: "変更を取り消す / やり直す"),
        ]),
        ("表示とファイル", [
            ShortcutHint(key: "I", action: "撮影情報を切替"),
            ShortcutHint(key: "F", action: "フィルムストリップを切替"),
            ShortcutHint(key: "⌘+ / ⌘−", action: "サムネイルサイズを変更"),
            ShortcutHint(key: "⌘O", action: "フォルダを開く"),
            ShortcutHint(key: "⌘E", action: "写真を書き出す"),
            ShortcutHint(key: "?", action: "このヘルプを閉じる"),
        ]),
    ]
}

struct ShortcutBarView: View {
    let mode: ViewMode
    let hasFiles: Bool
    let hasMultipleSelection: Bool

    var body: some View {
        HStack(spacing: 18) {
            ForEach(ShortcutGuide.primaryHints(
                mode: mode, hasFiles: hasFiles,
                hasMultipleSelection: hasMultipleSelection)) { hint in
                HStack(spacing: 5) {
                    Text(hint.key)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(hint.action)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .font(.system(size: 11, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.78))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("現在のショートカット")
    }
}

struct ShortcutOverlayView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("キーボードショートカット")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("閉じる (? / Esc)")
                }

                HStack(alignment: .top, spacing: 32) {
                    ForEach(Array(ShortcutGuide.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.headline)
                            ForEach(section.hints) { hint in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(hint.key)
                                        .font(.system(.body, design: .monospaced, weight: .semibold))
                                        .frame(width: 104, alignment: .trailing)
                                    Text(hint.action)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 900)
            .glassPanel(cornerRadius: 16)
            .padding(32)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("操作") {
                Toggle("評価後に自動で次へ進む", isOn: $model.autoAdvanceAfterRating)
            }
            Section("表示") {
                Toggle("下部にショートカットを表示", isOn: $model.showShortcutBar)
            }
            Section("選別アシスト") {
                Toggle("近接カットを自動スタック", isOn: $model.autoStackNearbyShots)
                Toggle("技術品質をバックグラウンド解析", isOn: $model.analyzeTechnicalQuality)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 340)
        .navigationTitle("設定")
    }
}
