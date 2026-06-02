import Foundation

struct BiquadCoefficients: Sendable, Hashable {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    static let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

struct BiquadFilter {
    var c: BiquadCoefficients = .passthrough
    private var z1: Float = 0
    private var z2: Float = 0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        // Transposed Direct Form II
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

enum BiquadDesign {
    static func coefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        guard band.isEnabled else { return .passthrough }

        let fs = Float(sampleRate)
        let f0 = max(20.0, min(20_000.0, band.frequencyHz))
        let w0 = 2.0 * Float.pi * Float(f0) / fs
        let cw0 = cos(w0)
        let sw0 = sin(w0)

        let q = max(0.0001, Float(band.q))
        let gainDB = Float(band.gainDB)

        switch band.type {
        case .lowPass:
            let alpha = sw0 / (2.0 * q)
            let b0 = (1.0 - cw0) / 2.0
            let b1 = 1.0 - cw0
            let b2 = (1.0 - cw0) / 2.0
            let a0 = 1.0 + alpha
            let a1 = -2.0 * cw0
            let a2 = 1.0 - alpha
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .highPass:
            let alpha = sw0 / (2.0 * q)
            let b0 = (1.0 + cw0) / 2.0
            let b1 = -(1.0 + cw0)
            let b2 = (1.0 + cw0) / 2.0
            let a0 = 1.0 + alpha
            let a1 = -2.0 * cw0
            let a2 = 1.0 - alpha
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .peaking:
            let a = pow(10.0, gainDB / 40.0)
            let alpha = sw0 / (2.0 * q)
            let b0 = 1.0 + alpha * a
            let b1 = -2.0 * cw0
            let b2 = 1.0 - alpha * a
            let a0 = 1.0 + alpha / a
            let a1 = -2.0 * cw0
            let a2 = 1.0 - alpha / a
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .lowShelf:
            let a = pow(10.0, gainDB / 40.0)
            let s: Float = max(0.1, min(4.0, q)) // shelf slope
            let alpha = (sw0 / 2.0) * sqrt((a + 1.0 / a) * (1.0 / s - 1.0) + 2.0)
            let sqrtA = sqrt(a)
            let twoSqrtAAlpha = 2.0 * sqrtA * alpha

            let b0 = a * ((a + 1.0) - (a - 1.0) * cw0 + twoSqrtAAlpha)
            let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cw0)
            let b2 = a * ((a + 1.0) - (a - 1.0) * cw0 - twoSqrtAAlpha)
            let a0 = (a + 1.0) + (a - 1.0) * cw0 + twoSqrtAAlpha
            let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cw0)
            let a2 = (a + 1.0) + (a - 1.0) * cw0 - twoSqrtAAlpha
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .bandPass:
            // RBJ cookbook: bandpass with constant peak gain = 1.
            let alpha = sw0 / (2.0 * q)
            let b0 = alpha
            let b1: Float = 0
            let b2 = -alpha
            let a0 = 1.0 + alpha
            let a1 = -2.0 * cw0
            let a2 = 1.0 - alpha
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .notch:
            // RBJ cookbook: notch filter.
            let alpha = sw0 / (2.0 * q)
            let b0: Float = 1
            let b1 = -2.0 * cw0
            let b2: Float = 1
            let a0 = 1.0 + alpha
            let a1 = -2.0 * cw0
            let a2 = 1.0 - alpha
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)

        case .highShelf:
            let a = pow(10.0, gainDB / 40.0)
            let s: Float = max(0.1, min(4.0, q)) // shelf slope
            let alpha = (sw0 / 2.0) * sqrt((a + 1.0 / a) * (1.0 / s - 1.0) + 2.0)
            let sqrtA = sqrt(a)
            let twoSqrtAAlpha = 2.0 * sqrtA * alpha

            let b0 = a * ((a + 1.0) + (a - 1.0) * cw0 + twoSqrtAAlpha)
            let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cw0)
            let b2 = a * ((a + 1.0) + (a - 1.0) * cw0 - twoSqrtAAlpha)
            let a0 = (a + 1.0) - (a - 1.0) * cw0 + twoSqrtAAlpha
            let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cw0)
            let a2 = (a + 1.0) - (a - 1.0) * cw0 - twoSqrtAAlpha
            return normalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
        }
    }

    @inline(__always)
    private static func normalize(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) -> BiquadCoefficients {
        guard a0 != 0 else { return .passthrough }
        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}
