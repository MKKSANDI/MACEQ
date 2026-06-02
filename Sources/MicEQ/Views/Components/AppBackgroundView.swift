import SwiftUI

struct AppBackgroundView: View {
    var body: some View {
        MACQTheme.windowGradient
        .overlay {
            RadialGradient(
                colors: [
                    Color.cyan.opacity(0.20),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
        }
        .overlay {
            RadialGradient(
                colors: [
                    Color.blue.opacity(0.14),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 620
            )
        }
        .overlay {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.035),
                    Color.clear,
                    Color.cyan.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}
