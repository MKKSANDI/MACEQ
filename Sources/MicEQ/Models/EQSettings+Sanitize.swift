import Foundation

extension EQSettings {
    func sanitized(maxBands: Int = 24) -> EQSettings {
        var s = self
        s.preampDB = clamp(s.preampDB, -24, 24)
        s.outputGainDB = clamp(s.outputGainDB, -24, 24)

        if s.bands.count > maxBands {
            s.bands = Array(s.bands.prefix(maxBands))
        }
        if s.bands.count < maxBands {
            let defaults = EQSettings.default.bands
            if defaults.count >= maxBands {
                let start = s.bands.count
                if start < maxBands {
                    for i in start..<maxBands {
                        let d = defaults[i]
                        s.bands.append(EQBand(
                            isEnabled: d.isEnabled,
                            type: d.type,
                            frequencyHz: d.frequencyHz,
                            gainDB: d.gainDB,
                            q: d.q
                        ))
                    }
                }
            }
        }

        for i in s.bands.indices {
            s.bands[i].frequencyHz = clamp(s.bands[i].frequencyHz, 20, 20_000)
            s.bands[i].gainDB = clamp(s.bands[i].gainDB, -24, 24)
            s.bands[i].q = clamp(s.bands[i].q, 0.1, 18)
        }

        // Noise gate
        s.noiseGate.thresholdDB = clamp(s.noiseGate.thresholdDB, -80, 0)
        s.noiseGate.hysteresisDB = clamp(s.noiseGate.hysteresisDB, 0, 12)
        s.noiseGate.rangeDB = clamp(s.noiseGate.rangeDB, 0, 80)
        s.noiseGate.attackMs = clamp(s.noiseGate.attackMs, 0, 50)
        s.noiseGate.holdMs = clamp(s.noiseGate.holdMs, 0, 500)
        s.noiseGate.releaseMs = clamp(s.noiseGate.releaseMs, 0, 1500)
        if s.noiseGate.rangeDB <= 0 { s.noiseGate.isEnabled = false }

        // Compressor
        s.compressor.thresholdDB = clamp(s.compressor.thresholdDB, -60, 0)
        s.compressor.ratio = clamp(s.compressor.ratio, 1, 20)
        s.compressor.kneeDB = clamp(s.compressor.kneeDB, 0, 24)
        s.compressor.attackMs = clamp(s.compressor.attackMs, 0, 50)
        s.compressor.releaseMs = clamp(s.compressor.releaseMs, 5, 1000)
        s.compressor.makeupGainDB = clamp(s.compressor.makeupGainDB, -12, 18)
        if s.compressor.ratio <= 1.01 { s.compressor.isEnabled = false }

        // De-esser
        s.deEsser.frequencyHz = clamp(s.deEsser.frequencyHz, 2000, 12_000)
        s.deEsser.q = clamp(s.deEsser.q, 0.3, 10)
        s.deEsser.thresholdDB = clamp(s.deEsser.thresholdDB, -60, 0)
        s.deEsser.ratio = clamp(s.deEsser.ratio, 1, 20)
        s.deEsser.attackMs = clamp(s.deEsser.attackMs, 0, 20)
        s.deEsser.releaseMs = clamp(s.deEsser.releaseMs, 10, 500)
        s.deEsser.maxReductionDB = clamp(s.deEsser.maxReductionDB, 0, 24)
        if s.deEsser.ratio <= 1.01 || s.deEsser.maxReductionDB <= 0 { s.deEsser.isEnabled = false }

        // Voice isolation
        s.voiceIsolation.strength = clamp(s.voiceIsolation.strength, 0, 100)
        s.voiceIsolation.noiseFloorDB = clamp(s.voiceIsolation.noiseFloorDB, -90, -10)
        s.voiceIsolation.speechThresholdDB = clamp(s.voiceIsolation.speechThresholdDB, -80, 0)
        s.voiceIsolation.reductionDB = clamp(s.voiceIsolation.reductionDB, 0, 80)
        s.voiceIsolation.focusLowHz = clamp(s.voiceIsolation.focusLowHz, 40, 400)
        s.voiceIsolation.focusHighHz = clamp(s.voiceIsolation.focusHighHz, 2_000, 18_000)
        if s.voiceIsolation.focusHighHz <= s.voiceIsolation.focusLowHz + 500 {
            s.voiceIsolation.focusHighHz = s.voiceIsolation.focusLowHz + 500
        }
        s.voiceIsolation.attackMs = clamp(s.voiceIsolation.attackMs, 0, 80)
        s.voiceIsolation.releaseMs = clamp(s.voiceIsolation.releaseMs, 20, 2_000)
        s.voiceIsolation.presenceBoostDB = clamp(s.voiceIsolation.presenceBoostDB, -6, 8)
        if s.voiceIsolation.strength <= 0 || s.voiceIsolation.reductionDB <= 0 {
            s.voiceIsolation.isEnabled = false
        }

        return s
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(hi, max(lo, v))
    }
}
