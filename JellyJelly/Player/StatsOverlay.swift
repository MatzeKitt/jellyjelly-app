import SwiftUI

/// "Stats for nerds": what is playing, how, and how healthy the buffer is.
struct StatsOverlay: View {
    var model: PlayerModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Playback Stats")
                    .font(.system(size: 14, weight: .heavy))
                Spacer()
                Button {
                    model.toggleStats()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            BufferGraph(samples: model.bufferHistory, target: Double(AppSettings.shared.bufferAheadSeconds))
                .frame(height: 54)

            // Grow with the content and only scroll when the window is too short.
            ViewThatFits(in: .vertical) {
                sections
                ScrollView {
                    sections
                }
                .scrollIndicators(.never)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .onHover { model.isInteractingWithControls = $0 }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.statsSections) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(palette.accent)
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.label)
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 104, alignment: .leading)
                            Text(row.value)
                                .foregroundStyle(color(for: row.highlight))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    }
                }
            }
        }
    }

    private func color(for highlight: StatRow.Highlight) -> Color {
        switch highlight {
        case .none: .white.opacity(0.92)
        case .good: Color(hex: 0x86EFAC)
        case .warning: Color(hex: 0xFCD34D)
        }
    }
}

/// Seconds buffered ahead over the last two minutes.
private struct BufferGraph: View {
    var samples: [Double]
    var target: Double
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BUFFER AHEAD")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(palette.accent)
                Spacer()
                Text(String(format: "%.0f s", samples.last ?? 0))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
            }
            Canvas { context, size in
                guard samples.count > 1 else {
                    return
                }
                let peak = max(samples.max() ?? 1, min(target, 60), 10)
                let step = size.width / CGFloat(max(samples.count - 1, 1))
                var line = Path()
                for (index, value) in samples.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(min(value / peak, 1))))
                    if index == 0 {
                        line.move(to: point)
                    } else {
                        line.addLine(to: point)
                    }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * step, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [palette.accent.opacity(0.45), palette.accent.opacity(0.02)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(palette.accent), lineWidth: 1.5)
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
