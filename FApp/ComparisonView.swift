import SwiftUI

struct ComparisonView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(model.comparisonURLs.prefix(2).enumerated()), id: \.element) {
                slot, url in
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let presented = model.comparisonFrames[url] {
                        MetalImageView(
                            presented: presented,
                            zoomMode: model.zoomMode,
                            onPresent: { _, _ in },
                            register: { model.registerComparisonView($0, slot: slot) },
                            onPanChange: { model.synchronizeComparisonPan($0) })
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }

                    HStack(spacing: 8) {
                        Text(slot == 0 ? "A" : "B")
                            .font(.headline.monospaced().weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 26, height: 26)
                            .background(.white, in: RoundedRectangle(cornerRadius: 5))
                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                    }
                    .foregroundStyle(.white)
                    .padding(8)
                    .glassPanel(cornerRadius: 8)
                    .padding(12)
                }
            }
        }
        .background(Color(white: 0.08))
    }
}
