import SwiftUI

struct EQGraphView: View, Equatable {
    let settings: EQSettings

    nonisolated static func == (lhs: EQGraphView, rhs: EQGraphView) -> Bool {
        lhs.settings == rhs.settings
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)

            drawGrid(context: &context, rect: rect)
            drawResponse(context: &context, rect: rect)
            drawBandDots(context: &context, rect: rect)
        }
        .macqPanel(cornerRadius: 10)
        .padding(.horizontal, 14)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Text("Response")
                    .font(.headline)
                Text(settings.isBypassed ? "Bypassed" : "Live")
                    .font(.caption)
                    .foregroundStyle(settings.isBypassed ? Color.secondary : Color.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MACQTheme.controlGradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 16)
            .padding(.leading, 22)
        }
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect) {
        var path = Path()

        // Horizontal dB lines
        let dbLines: [Double] = [-24, -12, 0, 12, 24]
        for db in dbLines {
            let y = yForDB(db, in: rect)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        // Vertical frequency lines (rough log scale markers)
        let freqs: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
        for f in freqs {
            let x = xForHz(f, in: rect)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        context.stroke(
            path,
            with: .color(Color.primary.opacity(0.08)),
            lineWidth: 1
        )

        // 0 dB emphasis
        var zero = Path()
        let y0 = yForDB(0, in: rect)
        zero.move(to: CGPoint(x: rect.minX, y: y0))
        zero.addLine(to: CGPoint(x: rect.maxX, y: y0))
        context.stroke(zero, with: .color(Color.primary.opacity(0.18)), lineWidth: 1.5)
    }

    private func drawResponse(context: inout GraphicsContext, rect: CGRect) {
        guard settings.isBypassed == false else { return }

        var path = Path()
        let logs = Self.logFrequencyBins
        let enabledBandCount = settings.bands.reduce(into: 0) { acc, b in
            if b.isEnabled { acc += 1 }
        }

        withUnsafeTemporaryAllocation(of: BandParam.self, capacity: max(1, enabledBandCount)) { buf in
            var n = 0
            for band in settings.bands where band.isEnabled {
                let center = log10(max(20, min(20_000, band.frequencyHz)))
                let width = max(0.03, 0.18 / max(0.2, band.q))
                buf[n] = BandParam(center: center, invWidth: 1.0 / width, gain: band.gainDB)
                n += 1
            }

            for i in 0..<Self.responsePoints {
                // Lightweight UI preview response:
                // sum of gaussians in log-frequency space (not an exact filter response).
                var db: Double = 0
                let logX = logs[i]
                for j in 0..<n {
                    let p = buf[j]
                    let d = (logX - p.center) * p.invWidth
                    db += p.gain * exp(-0.5 * d * d)
                }

                let t = (logX - Self.logMin) / Self.logSpan
                let xPos = rect.minX + CGFloat(t) * rect.width
                let y = yForDB(db, in: rect)
                if i == 0 { path.move(to: CGPoint(x: xPos, y: y)) }
                else { path.addLine(to: CGPoint(x: xPos, y: y)) }
            }
        }

        context.stroke(
            path,
            with: .color(Color.accentColor.opacity(0.9)),
            lineWidth: 2
        )
    }

    private struct BandParam {
        var center: Double
        var invWidth: Double
        var gain: Double
    }

    private func drawBandDots(context: inout GraphicsContext, rect: CGRect) {
        for band in settings.bands {
            let x = xForHz(band.frequencyHz, in: rect)
            let y = yForDB(band.gainDB, in: rect)
            let r: CGFloat = band.isEnabled ? 4.5 : 3.5
            let dot = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            context.fill(
                Path(ellipseIn: dot),
                with: .color(band.isEnabled ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.35))
            )
        }
    }

    private func xForHz(_ hz: Double, in rect: CGRect) -> CGFloat {
        let clamped = max(20.0, min(20_000.0, hz))
        let t = (log10(clamped) - log10(20.0)) / (log10(20_000.0) - log10(20.0))
        return rect.minX + CGFloat(t) * rect.width
    }

    private func yForDB(_ db: Double, in rect: CGRect) -> CGFloat {
        let clamped = max(-24.0, min(24.0, db))
        let t = (clamped - (-24.0)) / (24.0 - (-24.0)) // 0..1
        return rect.maxY - CGFloat(t) * rect.height
    }

    private static let responsePoints: Int = 240
    private static let logMin: Double = log10(20.0)
    private static let logMax: Double = log10(20_000.0)
    private static let logSpan: Double = logMax - logMin
    private static let logFrequencyBins: [Double] = {
        guard responsePoints > 1 else { return [logMin] }
        return (0..<responsePoints).map { i in
            logMin + (Double(i) / Double(responsePoints - 1)) * logSpan
        }
    }()
}
