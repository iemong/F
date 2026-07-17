import AppKit
import AppCore
import SwiftUI

/// カラーラベルの表示ヘルパー
enum LabelColorStyle {
    static func color(_ label: String) -> Color {
        switch label {
        case "Red": .red
        case "Yellow": .yellow
        case "Green": .green
        case "Blue": .blue
        default: .purple
        }
    }

    static func displayName(_ label: String) -> String {
        switch label {
        case "Red": "赤"
        case "Yellow": "黄"
        case "Green": "緑"
        case "Blue": "青"
        default: label
        }
    }
}

extension View {
    /// Liquid Glass パネル（macOS 26+）。旧OSはマテリアルにフォールバック
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                .ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// サムネイルグリッド。セルは遅延生成（表示された分だけデコード）
struct GridView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int(geometry.size.width / max(120, model.gridCellSize)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 8), count: columns),
                        spacing: 8
                    ) {
                        ForEach(model.gridVisibleFiles, id: \.self) { url in
                            let stack = model.stack(for: url)
                            ThumbnailCell(
                                url: url,
                                isSelected: url == model.currentURL
                                    || model.gridSelection.contains(url),
                                isPrimary: url == model.currentURL,
                                rating: model.ratings[url] ?? 0,
                                label: model.labels[url],
                                provider: model.thumbnails,
                                stackCount: stack?.members.count ?? 0,
                                stackExpanded: stack.map {
                                    model.expandedStackIDs.contains($0.id)
                                } ?? false,
                                quality: model.qualityByURL[url],
                                qualityRank: model.qualityRank(for: url, in: stack),
                                onToggleStack: { model.toggleStack(containing: url) },
                                onCompareStack: {
                                    if let stack { model.beginComparison(with: stack.members) }
                                }
                            )
                            .id(url)
                            .onTapGesture(count: 2) {
                                model.selectGridItem(url, command: false, shift: false)
                                model.openSelected()
                            }
                            .onTapGesture {
                                let modifiers = NSEvent.modifierFlags
                                    .intersection(.deviceIndependentFlagsMask)
                                model.selectGridItem(
                                    url,
                                    command: modifiers.contains(.command),
                                    shift: modifiers.contains(.shift))
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.currentIndex) { _, newIndex in
                    guard model.visibleFiles.indices.contains(newIndex) else { return }
                    let selected = model.visibleFiles[newIndex]
                    proxy.scrollTo(
                        model.gridVisibleFiles.contains(selected)
                            ? selected : model.stack(for: selected)?.representative)
                }
            }
            .onAppear { model.gridColumns = columns }
            .onChange(of: columns) { _, newValue in model.gridColumns = newValue }
            .overlay {
                if model.visibleFiles.isEmpty {
                    Text(
                        model.filter.isActive
                            ? "フィルター条件に合うファイルがありません"
                            : "\(model.fileTypeMode.displayName)のファイルがありません（ツールバーで種別を切替）"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                sizeControl
            }
        }
        .background(Color.black)
    }

    /// 写真.app風のサムネイルサイズコントロール（右下フローティング）
    private var sizeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: sizeBinding, in: 120 ... 400)
                .controlSize(.mini)
                .frame(width: 110)
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 999)
        .padding(12)
        .help("サムネイルの大きさ (⌘+ / ⌘−)")
    }

    private var sizeBinding: Binding<CGFloat> {
        Binding(get: { model.gridCellSize }, set: { model.gridCellSize = $0 })
    }
}

struct ThumbnailCell: View {
    let url: URL
    let isSelected: Bool
    let isPrimary: Bool
    let rating: Int
    let label: String?
    let provider: ThumbnailProvider
    let stackCount: Int
    let stackExpanded: Bool
    let quality: QualityMetrics?
    let qualityRank: (rank: Int, total: Int)?
    let onToggleStack: () -> Void
    let onCompareStack: () -> Void

    @State private var thumbnail: ThumbImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color(white: 0.12))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail.cgImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .rotationEffect(.degrees(thumbnail.rotationDegrees))
                            .padding(4)
                    }
                }
                .clipped()

            HStack(spacing: 6) {
                if let label {
                    Circle()
                        .fill(LabelColorStyle.color(label))
                        .frame(width: 8, height: 8)
                }
                if rating == -1 {
                    Text("✕")
                        .foregroundStyle(.red)
                } else if rating > 0 {
                    Text(String(repeating: "★", count: rating))
                        .foregroundStyle(.yellow)
                }
                Text(url.lastPathComponent)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glassPanel(cornerRadius: 5)
            .padding(4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? (isPrimary ? Color.accentColor : .cyan) : .clear,
                    lineWidth: isPrimary ? 3 : 2)
        )
        .overlay(alignment: .topTrailing) {
            if stackCount > 1 {
                HStack(spacing: 5) {
                    Button(action: onCompareStack) {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("スタック内の写真をA/B比較")
                    Button(action: onToggleStack) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.stack")
                            Text("\(stackCount)")
                            Image(systemName: stackExpanded ? "chevron.up" : "chevron.down")
                        }
                    }
                    .help(stackExpanded ? "スタックを折りたたむ" : "スタックを展開")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .glassPanel(cornerRadius: 7)
                .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let quality {
                QualityBadgeView(metrics: quality, rank: qualityRank)
                    .padding(6)
            }
        }
        .task(id: url) {
            thumbnail = await provider.image(for: url)
        }
    }
}

struct QualityBadgeView: View {
    let metrics: QualityMetrics
    let rank: (rank: Int, total: Int)?
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: warningCount > 0 ? "exclamationmark.triangle.fill" : "gauge")
                Text("\(Int(metrics.overallScore.rounded()))")
                if let rank {
                    Text("#\(rank.rank)/\(rank.total)")
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(warningCount > 0 ? .yellow : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .glassPanel(cornerRadius: 7)
        }
        .buttonStyle(.plain)
        .help("技術品質の判定根拠を表示")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 9) {
                Text("技術品質 \(Int(metrics.overallScore.rounded())) / 100")
                    .font(.headline)
                metricRow("シャープネス", metrics.sharpness, warning: metrics.sharpness < 0.18)
                metricRow("コントラスト", metrics.contrast, warning: metrics.contrast < 0.16)
                metricRow(
                    "白飛び", metrics.highlightClipping,
                    warning: metrics.highlightClipping > 0.02, lowerIsBetter: true)
                metricRow(
                    "黒つぶれ", metrics.shadowClipping,
                    warning: metrics.shadowClipping > 0.04, lowerIsBetter: true)
                if let rank {
                    Divider()
                    Text("スタック内順位 \(rank.rank) / \(rank.total)")
                        .fontWeight(.semibold)
                }
                Text("自動評価ではなく、選別時の技術的な参考値です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 290)
        }
    }

    private var warningCount: Int {
        (metrics.sharpness < 0.18 ? 1 : 0)
            + (metrics.contrast < 0.16 ? 1 : 0)
            + (metrics.highlightClipping > 0.02 ? 1 : 0)
            + (metrics.shadowClipping > 0.04 ? 1 : 0)
    }

    @ViewBuilder
    private func metricRow(
        _ title: String, _ value: Double, warning: Bool, lowerIsBetter: Bool = false
    ) -> some View {
        HStack {
            Image(systemName: warning ? "exclamationmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(warning ? .yellow : .green)
            Text(title)
            Spacer()
            Text("\(value * 100, specifier: "%.1f")%")
                .monospacedDigit()
        }
        .help(lowerIsBetter ? "値が低いほど良好" : "値が高いほど良好")
    }
}
