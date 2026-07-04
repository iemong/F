import SwiftUI

/// Tキーで開くキーワード（任意名タグ）編集シート。カンマ区切りで入力
struct KeywordEditorView: View {
    @Bindable var model: AppModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.currentURL?.lastPathComponent ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("キーワード（カンマ区切り）", text: $model.keywordDraft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { model.commitKeywordEditing() }

            let suggestions = model.allFolderKeywords.filter {
                !model.keywordDraft.contains($0)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions.prefix(12), id: \.self) { keyword in
                            Button("#\(keyword)") {
                                if model.keywordDraft.trimmingCharacters(in: .whitespaces)
                                    .isEmpty
                                {
                                    model.keywordDraft = keyword
                                } else {
                                    model.keywordDraft += ", \(keyword)"
                                }
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { model.cancelKeywordEditing() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.commitKeywordEditing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }
}
