import SwiftUI

/// 1枚表示の下部に出すフィルムストリップ（Fキーでトグル）。
/// サムネイルはグリッドと同じ ThumbnailProvider（LRU 320MB）を共有する
struct FilmstripView: View {
    let model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(model.visibleFiles.enumerated()), id: \.element) { index, url in
                        FilmstripCell(
                            url: url,
                            isCurrent: index == model.currentIndex,
                            rating: model.ratings[url] ?? 0,
                            label: model.labels[url],
                            typeBadge: model.fileTypeMode == .both
                                ? url.pathExtension.uppercased() : nil,
                            provider: model.thumbnails
                        )
                        .id(url)
                        .onTapGesture { model.jumpTo(index) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: model.currentIndex) { _, newIndex in
                guard model.visibleFiles.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(model.visibleFiles[newIndex], anchor: .center)
                }
            }
            .onAppear {
                guard model.visibleFiles.indices.contains(model.currentIndex) else { return }
                proxy.scrollTo(model.visibleFiles[model.currentIndex], anchor: .center)
            }
        }
        .frame(height: 72)
        .background(.black.opacity(0.4))
    }
}

struct FilmstripCell: View {
    let url: URL
    let isCurrent: Bool
    let rating: Int
    let label: String?
    /// 両方モードのときだけ拡張子を出してペアを見分ける（それ以外は nil）
    let typeBadge: String?
    let provider: ThumbnailProvider

    @State private var thumbnail: ThumbImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color(white: 0.15))
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail.cgImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .rotationEffect(.degrees(thumbnail.rotationDegrees))
                            .padding(1)
                    }
                }
                .clipped()

            HStack(spacing: 3) {
                if let label {
                    Circle()
                        .fill(LabelColorStyle.color(label))
                        .frame(width: 6, height: 6)
                }
                if rating == -1 {
                    Text("✕").foregroundStyle(.red)
                } else if rating > 0 {
                    Text("★\(rating)").foregroundStyle(.yellow)
                }
            }
            .font(.system(size: 9, weight: .bold))
            .padding(3)
        }
        .frame(width: 60, height: 60)
        .opacity(rating == -1 ? 0.4 : 1)
        .overlay(alignment: .topTrailing) {
            if let typeBadge {
                Text(typeBadge)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
        )
        .task(id: url) {
            thumbnail = await provider.image(for: url)
        }
    }
}
