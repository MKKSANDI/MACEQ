import SwiftUI

enum MACQTheme {
    static let windowGradient = LinearGradient(
        colors: [
            Color(red: 0.00, green: 0.01, blue: 0.04),
            Color(red: 0.01, green: 0.06, blue: 0.14),
            Color(red: 0.01, green: 0.02, blue: 0.08),
            Color(red: 0.00, green: 0.00, blue: 0.02),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panelGradient = LinearGradient(
        colors: [
            Color(red: 0.03, green: 0.11, blue: 0.22).opacity(0.82),
            Color(red: 0.01, green: 0.04, blue: 0.12).opacity(0.94),
            Color(red: 0.00, green: 0.01, blue: 0.05).opacity(0.98),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let controlGradient = LinearGradient(
        colors: [
            Color.cyan.opacity(0.22),
            Color.blue.opacity(0.10),
            Color(red: 0.01, green: 0.04, blue: 0.10).opacity(0.86),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let selectedGradient = LinearGradient(
        colors: [
            Color.cyan.opacity(0.42),
            Color.blue.opacity(0.24),
            Color(red: 0.05, green: 0.02, blue: 0.16).opacity(0.46),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panelStroke = Color.cyan.opacity(0.24)
    static let strongStroke = Color.cyan.opacity(0.52)
    static let mutedText = Color.white.opacity(0.62)
    static let electricCyan = Color(red: 0.38, green: 0.86, blue: 1.0)
}

struct MACQGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.88))

            configuration.content
                .foregroundStyle(Color.white.opacity(0.86))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MACQTheme.panelGradient)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(MACQTheme.panelStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.cyan.opacity(0.05), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }
}

struct MACQPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var selected: Bool = false

    func body(content: Content) -> some View {
        content
            .background(selected ? MACQTheme.selectedGradient : MACQTheme.panelGradient)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(selected ? MACQTheme.strongStroke : MACQTheme.panelStroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: selected ? Color.cyan.opacity(0.16) : .clear, radius: selected ? 14 : 0, y: selected ? 6 : 0)
            .animation(.easeOut(duration: 0.16), value: selected)
    }
}

extension View {
    func macqPanel(cornerRadius: CGFloat = 10, selected: Bool = false) -> some View {
        modifier(MACQPanelModifier(cornerRadius: cornerRadius, selected: selected))
    }

    func macqRootSurface() -> some View {
        background(AppBackgroundView())
            .preferredColorScheme(.dark)
            .groupBoxStyle(MACQGroupBoxStyle())
    }

    func macqTransparentScroll() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}
