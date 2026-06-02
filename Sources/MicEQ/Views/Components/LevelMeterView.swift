import SwiftUI

struct LevelMeterView: View {
    let levelDB: Double

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let fill = CGFloat(normalizedLevel(levelDB)) * w

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.02, green: 0.06, blue: 0.12).opacity(0.92))

                RoundedRectangle(cornerRadius: 6)
                    .fill(gradient)
                    .frame(width: max(0, fill))
            }
        }
    }

    private func normalizedLevel(_ db: Double) -> Double {
        // -60 dB .. 0 dB
        let clamped = max(-60.0, min(0.0, db))
        return (clamped + 60.0) / 60.0
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                .green.opacity(0.95),
                .yellow.opacity(0.95),
                .orange.opacity(0.95),
                .red.opacity(0.95),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
