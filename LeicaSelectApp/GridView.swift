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

    private static let cellSize: CGFloat = 196

    var body: some View {
        GeometryReader { geometry in
            let columns = max(2, Int(geometry.size.width / Self.cellSize))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 8), count: columns),
                        spacing: 8
                    ) {
                        ForEach(Array(model.visibleFiles.enumerated()), id: \.element) { index, url in
                            ThumbnailCell(
                                url: url,
                                isSelected: index == model.currentIndex,
                                rating: model.ratings[url] ?? 0,
                                label: model.labels[url],
                                provider: model.thumbnails
                            )
                            .id(url)
                            .onTapGesture(count: 2) {
                                model.select(index)
                                model.openSelected()
                            }
                            .onTapGesture {
                                model.select(index)
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.currentIndex) { _, newIndex in
                    guard model.visibleFiles.indices.contains(newIndex) else { return }
                    proxy.scrollTo(model.visibleFiles[newIndex])
                }
            }
            .onAppear { model.gridColumns = columns }
            .onChange(of: columns) { _, newValue in model.gridColumns = newValue }
        }
        .background(Color.black)
    }
}

struct ThumbnailCell: View {
    let url: URL
    let isSelected: Bool
    let rating: Int
    let label: String?
    let provider: ThumbnailProvider

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
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .task(id: url) {
            thumbnail = await provider.image(for: url)
        }
    }
}
