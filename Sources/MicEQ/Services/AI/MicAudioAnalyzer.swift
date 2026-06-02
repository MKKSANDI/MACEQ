import Accelerate
import Foundation

struct MicAudioAnalysis: Hashable, Sendable {
    struct BandEnergy: Hashable, Sendable, Identifiable {
        let id: String
        let rangeHz: ClosedRange<Double>
        let rmsDBFS: Double
    }

    let sampleRate: Double
    let durationSeconds: Double

    let rmsDBFS: Double
    let peakDBFS: Double
    let dcOffset: Double
    let noiseFloorDBFS: Double
    let snrEstimateDB: Double
    let dynamicRangeDB: Double
    let zeroCrossingRateHz: Double
    let spectralCentroidHz: Double?
    let crestFactorDB: Double
    let levelStdDevDB: Double
    let clippedSamplePercent: Double
    let silencePercent: Double

    let estimatedPitchHz: Double?
    let pitchStdHz: Double?
    let voicedRatio: Double

    let bandEnergies: [BandEnergy]

    /// Structured JSON for LLM prompts (stable keys, compact numeric values).
    var promptJSON: String {
        struct Payload: Encodable {
            struct Band: Encodable {
                let rangeHz: [Double]
                let rmsDBFS: Double
            }

            let sampleRate: Double
            let durationSeconds: Double

            let rmsDBFS: Double
            let peakDBFS: Double
            let dcOffset: Double
            let noiseFloorDBFS: Double
            let snrEstimateDB: Double
            let dynamicRangeDB: Double
            let crestFactorDB: Double
            let levelStdDevDB: Double
            let zeroCrossingRateHz: Double
            let spectralCentroidHz: Double?
            let clippedSamplePercent: Double
            let silencePercent: Double

            let estimatedPitchHz: Double?
            let pitchStdHz: Double?
            let voicedRatio: Double

            let bandEnergies: [Band]
        }

        let payload = Payload(
            sampleRate: sampleRate,
            durationSeconds: durationSeconds,
            rmsDBFS: rmsDBFS,
            peakDBFS: peakDBFS,
            dcOffset: dcOffset,
            noiseFloorDBFS: noiseFloorDBFS,
            snrEstimateDB: snrEstimateDB,
            dynamicRangeDB: dynamicRangeDB,
            crestFactorDB: crestFactorDB,
            levelStdDevDB: levelStdDevDB,
            zeroCrossingRateHz: zeroCrossingRateHz,
            spectralCentroidHz: spectralCentroidHz,
            clippedSamplePercent: clippedSamplePercent,
            silencePercent: silencePercent,
            estimatedPitchHz: estimatedPitchHz,
            pitchStdHz: pitchStdHz,
            voicedRatio: voicedRatio,
            bandEnergies: bandEnergies.map { b in
                Payload.Band(rangeHz: [b.rangeHz.lowerBound, b.rangeHz.upperBound], rmsDBFS: b.rmsDBFS)
            }
        )

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(payload)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    var summaryText: String {
        var lines: [String] = []
        lines.append(String(format: "Duration: %.2fs @ %.0fHz", durationSeconds, sampleRate))
        lines.append(String(format: "Levels: RMS %.1f dBFS, Peak %.1f dBFS (crest %.1f dB), Noise floor ~%.1f dBFS, SNR~%.1f dB, DynRange~%.1f dB, Level σ %.1f dB, DC %.4f",
                            rmsDBFS, peakDBFS, crestFactorDB, noiseFloorDBFS, snrEstimateDB, dynamicRangeDB, levelStdDevDB, dcOffset))
        lines.append(String(format: "Clipping: %.3f%% of samples near full-scale; Silence: %.1f%%",
                            clippedSamplePercent, silencePercent))
        lines.append(String(format: "Timing: Zero-crossing rate %.0f/s", zeroCrossingRateHz))
        if let centroid = spectralCentroidHz {
            lines.append(String(format: "Spectral: centroid ~%.0f Hz (brightness)", centroid))
        }
        if let f0 = estimatedPitchHz, let sd = pitchStdHz {
            lines.append(String(format: "Pitch (F0): %.0f Hz (σ %.0f Hz), voiced %.0f%%", f0, sd, voicedRatio * 100.0))
        } else {
            lines.append(String(format: "Pitch (F0): unavailable, voiced %.0f%%", voicedRatio * 100.0))
        }
        lines.append("Band energy (RMS dBFS): " + bandEnergies.map { b in
            let lo = b.rangeHz.lowerBound
            let hi = b.rangeHz.upperBound
            let r = (hi >= 1000)
                ? String(format: "%.0f–%.0fkHz", lo, hi / 1000.0)
                : String(format: "%.0f–%.0fHz", lo, hi)
            return "\(r): \(String(format: "%.1f", b.rmsDBFS))"
        }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
}

enum MicAudioAnalyzer {
    static func analyzeWAV16Mono(_ wav: Data) throws -> MicAudioAnalysis {
        let parsed = try WAV16Mono.parse(wav)
        let sampleRate = Double(parsed.sampleRate)
        let samples = parsed.samples

        let duration = Double(samples.count) / sampleRate

        var rms: Float = 0
        var peak: Float = 0
        var mean: Float = 0
        var clippedCount = 0
        var silentCount = 0

        samples.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(buf.count))
            vDSP_maxmgv(buf.baseAddress!, 1, &peak, vDSP_Length(buf.count))
            vDSP_meanv(buf.baseAddress!, 1, &mean, vDSP_Length(buf.count))
        }

        for s in samples {
            if abs(s) >= 0.995 { clippedCount += 1 }
            if abs(s) <= 0.001 { silentCount += 1 }
        }

        let rmsDB = dbfs(rms)
        let peakDB = dbfs(peak)
        let crest = peakDB - rmsDB

        let envelope = windowedRMS(samples: samples, sampleRate: parsed.sampleRate, windowMs: 20, hopMs: 20)
        let levelStd = stdDevDB(fromRMS: envelope)

        let noiseFloorDB = percentileDB(fromRMS: envelope, percentile: 0.10)
        let voiceLevelDB = percentileDB(fromRMS: envelope, percentile: 0.90)
        let snrEstimate = max(0, voiceLevelDB - noiseFloorDB)
        let dynRange = max(0, peakDB - noiseFloorDB)

        let pitch = estimatePitch(samples: samples, sampleRate: parsed.sampleRate)

        let bands: [(String, ClosedRange<Double>)] = [
            ("20-40", 20...40),
            ("40-60", 40...60),
            ("60-90", 60...90),
            ("90-140", 90...140),
            ("140-200", 140...200),
            ("200-300", 200...300),
            ("300-500", 300...500),
            ("500-800", 500...800),
            ("800-1200", 800...1200),
            ("1200-2000", 1200...2000),
            ("2000-3500", 2000...3500),
            ("3500-5000", 3500...5000),
            ("5000-7000", 5000...7000),
            ("7000-10000", 7000...10_000),
            ("10000-14000", 10_000...14_000),
            ("14000-20000", 14_000...20_000),
        ]
        let energies = estimateBandEnergies(samples: samples, sampleRate: sampleRate, bands: bands)

        let zcr = zeroCrossingRate(samples: samples, durationSeconds: duration)
        let centroid = spectralCentroidHz(from: energies)

        return MicAudioAnalysis(
            sampleRate: sampleRate,
            durationSeconds: duration,
            rmsDBFS: rmsDB,
            peakDBFS: peakDB,
            dcOffset: Double(mean),
            noiseFloorDBFS: noiseFloorDB,
            snrEstimateDB: snrEstimate,
            dynamicRangeDB: dynRange,
            zeroCrossingRateHz: zcr,
            spectralCentroidHz: centroid,
            crestFactorDB: crest,
            levelStdDevDB: levelStd,
            clippedSamplePercent: samples.isEmpty ? 0 : (Double(clippedCount) / Double(samples.count) * 100.0),
            silencePercent: samples.isEmpty ? 0 : (Double(silentCount) / Double(samples.count) * 100.0),
            estimatedPitchHz: pitch.meanHz,
            pitchStdHz: pitch.stdHz,
            voicedRatio: pitch.voicedRatio,
            bandEnergies: energies
        )
    }

    private static func dbfs(_ x: Float) -> Double {
        guard x > 0 else { return -80 }
        let db = 20.0 * log10(Double(x))
        return max(-80, min(0, db))
    }

    private static func windowedRMS(samples: [Float], sampleRate: UInt32, windowMs: Double, hopMs: Double) -> [Float] {
        let windowFrames = max(1, Int(Double(sampleRate) * (windowMs / 1000.0)))
        let hopFrames = max(1, Int(Double(sampleRate) * (hopMs / 1000.0)))
        if samples.count < windowFrames { return [rms(samples)] }

        var out: [Float] = []
        out.reserveCapacity(max(1, (samples.count - windowFrames) / hopFrames))

        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while i + windowFrames <= samples.count {
                var r: Float = 0
                vDSP_rmsqv(base.advanced(by: i), 1, &r, vDSP_Length(windowFrames))
                out.append(r)
                i += hopFrames
            }
        }

        return out.isEmpty ? [rms(samples)] : out
    }

    private static func percentileDB(fromRMS rmsValues: [Float], percentile: Double) -> Double {
        guard rmsValues.isEmpty == false else { return -80 }
        var sorted = rmsValues
        sorted.sort()
        let p = max(0, min(1, percentile))
        let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
        return dbfs(sorted[idx])
    }

    private static func stdDevDB(fromRMS rmsValues: [Float]) -> Double {
        let dbs = rmsValues.map(dbfs)
        guard dbs.count >= 2 else { return 0 }
        let mean = dbs.reduce(0, +) / Double(dbs.count)
        let varSum = dbs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sqrt(varSum / Double(dbs.count - 1))
    }

    private static func rms(_ samples: [Float]) -> Float {
        var out: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress!, 1, &out, vDSP_Length(buf.count))
        }
        return out
    }

    private static func zeroCrossingRate(samples: [Float], durationSeconds: Double) -> Double {
        guard durationSeconds > 0, samples.count >= 2 else { return 0 }
        var crossings = 0
        var prev = samples[0]
        for i in 1..<samples.count {
            let cur = samples[i]
            if (prev >= 0 && cur < 0) || (prev < 0 && cur >= 0) {
                crossings += 1
            }
            prev = cur
        }
        return Double(crossings) / durationSeconds
    }

    private static func spectralCentroidHz(from bands: [MicAudioAnalysis.BandEnergy]) -> Double? {
        var num = 0.0
        var den = 0.0
        for b in bands {
            let lo = b.rangeHz.lowerBound
            let hi = b.rangeHz.upperBound
            let mid = sqrt(max(1, lo) * max(1, hi))
            let power = pow(10.0, b.rmsDBFS / 10.0) // convert dB to linear power-ish weight
            num += mid * power
            den += power
        }
        guard den > 0 else { return nil }
        return num / den
    }

    private static func estimateBandEnergies(
        samples: [Float],
        sampleRate: Double,
        bands: [(String, ClosedRange<Double>)]
    ) -> [MicAudioAnalysis.BandEnergy] {
        // Cascaded biquad HPF + LPF per band to approximate energy in that band.
        // Uses our RBJ biquad design to keep analysis consistent with the app EQ.
        var result: [MicAudioAnalysis.BandEnergy] = []
        var scratch = samples

        for (id, range) in bands {
            scratch = samples

            var hp = BiquadFilter()
            hp.c = BiquadDesign.coefficients(
                for: EQBand(type: .highPass, frequencyHz: range.lowerBound, gainDB: 0, q: 0.707),
                sampleRate: sampleRate
            )
            for n in scratch.indices {
                scratch[n] = hp.process(scratch[n])
            }

            var lp = BiquadFilter()
            lp.c = BiquadDesign.coefficients(
                for: EQBand(type: .lowPass, frequencyHz: range.upperBound, gainDB: 0, q: 0.707),
                sampleRate: sampleRate
            )
            for n in scratch.indices {
                scratch[n] = lp.process(scratch[n])
            }

            let bandRMS = rms(scratch)
            result.append(.init(id: id, rangeHz: range, rmsDBFS: dbfs(bandRMS)))
        }

        return result
    }

    private static func estimatePitch(samples: [Float], sampleRate: UInt32) -> (meanHz: Double?, stdHz: Double?, voicedRatio: Double) {
        // Faster autocorrelation pitch estimate:
        // - downsample to reduce compute
        // - 40ms windows, 20ms hop
        // - search 70..300 Hz
        let sr = Double(sampleRate)
        let targetSR = 12_000.0
        let dsFactor = max(1, Int(floor(sr / targetSR)))

        let ds = downsampleAveraging(samples, factor: dsFactor)
        let dsSR = sr / Double(dsFactor)

        let window = max(1, Int(dsSR * 0.040))
        let hop = max(1, Int(dsSR * 0.020))

        let minHz = 70.0
        let maxHz = 300.0
        let minLag = max(1, Int(dsSR / maxHz))
        let maxLag = max(minLag + 1, Int(dsSR / minHz))

        if ds.count < window + maxLag { return (nil, nil, 0) }

        var pitches: [Double] = []
        pitches.reserveCapacity(256)
        var voiced = 0
        var total = 0

        ds.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var idx = 0
            while idx + window + maxLag <= ds.count {
                let seg = base.advanced(by: idx)

                var segRMS: Float = 0
                vDSP_rmsqv(seg, 1, &segRMS, vDSP_Length(window))

                total += 1
                if segRMS < 0.01 { // ~ -40 dBFS: likely silence/unvoiced
                    idx += hop
                    continue
                }

                let (lag, confidence) = bestAutocorrelationLag(seg, length: window, minLag: minLag, maxLag: maxLag)
                if confidence > 0.35 {
                    voiced += 1
                    pitches.append(dsSR / Double(lag))
                }

                idx += hop
            }
        }

        let voicedRatio = total == 0 ? 0 : Double(voiced) / Double(total)
        guard pitches.isEmpty == false else { return (nil, nil, voicedRatio) }

        let mean = pitches.reduce(0, +) / Double(pitches.count)
        let varSum = pitches.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let std = sqrt(varSum / Double(max(1, pitches.count - 1)))
        return (mean, std, voicedRatio)
    }

    private static func bestAutocorrelationLag(
        _ x: UnsafePointer<Float>,
        length: Int,
        minLag: Int,
        maxLag: Int
    ) -> (lag: Int, confidence: Double) {
        // Normalized autocorrelation: r[lag] / r[0].
        // Uses vDSP dot products to stay fast in Swift.
        guard length > maxLag, minLag > 0, maxLag >= minLag else { return (minLag, 0) }

        var energy: Float = 0
        vDSP_dotpr(x, 1, x, 1, &energy, vDSP_Length(length))
        if energy <= 1e-9 { return (minLag, 0) }

        var bestLag = minLag
        var best: Float = -Float.infinity

        for lag in minLag...maxLag {
            let n = length - lag
            if n <= 0 { break }
            var dot: Float = 0
            vDSP_dotpr(x, 1, x.advanced(by: lag), 1, &dot, vDSP_Length(n))
            let norm = dot / energy
            if norm > best {
                best = norm
                bestLag = lag
            }
        }

        return (bestLag, Double(max(0, min(1, best))))
    }

    private static func downsampleAveraging(_ samples: [Float], factor: Int) -> [Float] {
        guard factor > 1, samples.count >= factor else { return samples }
        let outCount = samples.count / factor
        var out = [Float](repeating: 0, count: outCount)

        var src = 0
        for i in 0..<outCount {
            var sum: Float = 0
            for j in 0..<factor {
                sum += samples[src + j]
            }
            out[i] = sum / Float(factor)
            src += factor
        }

        return out
    }
}

private struct WAV16Mono {
    let sampleRate: UInt32
    let samples: [Float]

    static func parse(_ data: Data) throws -> WAV16Mono {
        guard data.count >= 44 else { throw WAVError("WAV too small") }

        func readU32LE(_ offset: Int) -> UInt32 {
            let b0 = UInt32(data[offset + 0])
            let b1 = UInt32(data[offset + 1]) << 8
            let b2 = UInt32(data[offset + 2]) << 16
            let b3 = UInt32(data[offset + 3]) << 24
            return b0 | b1 | b2 | b3
        }

        func readU16LE(_ offset: Int) -> UInt16 {
            let b0 = UInt16(data[offset + 0])
            let b1 = UInt16(data[offset + 1]) << 8
            return b0 | b1
        }

        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else { throw WAVError("Not a RIFF/WAVE file") }

        var fmtAudioFormat: UInt16?
        var fmtChannels: UInt16?
        var fmtSampleRate: UInt32?
        var fmtBitsPerSample: UInt16?
        var pcmData: Data?

        var cursor = 12
        while cursor + 8 <= data.count {
            let chunkID = String(data: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(readU32LE(cursor + 4))
            cursor += 8
            guard cursor + chunkSize <= data.count else { break }

            if chunkID == "fmt " {
                if chunkSize >= 16 {
                    fmtAudioFormat = readU16LE(cursor + 0)
                    fmtChannels = readU16LE(cursor + 2)
                    fmtSampleRate = readU32LE(cursor + 4)
                    fmtBitsPerSample = readU16LE(cursor + 14)
                }
            } else if chunkID == "data" {
                pcmData = data[cursor..<(cursor + chunkSize)]
            }

            cursor += chunkSize
            if (chunkSize % 2) == 1 { cursor += 1 } // pad
        }

        guard fmtAudioFormat == 1 else { throw WAVError("Unsupported WAV format (expected PCM)") }
        guard fmtChannels == 1 else { throw WAVError("Unsupported WAV channels (expected mono)") }
        guard fmtBitsPerSample == 16 else { throw WAVError("Unsupported WAV bit depth (expected 16-bit)") }
        guard let sr = fmtSampleRate else { throw WAVError("Missing WAV sample rate") }
        guard let pcmData else { throw WAVError("Missing WAV data chunk") }

        let sampleCount = pcmData.count / 2
        var out = [Float](repeating: 0, count: sampleCount)
        out.withUnsafeMutableBufferPointer { outBuf in
            pcmData.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self).baseAddress!
                var i = 0
                while i < sampleCount {
                    let lo = UInt16(src[i * 2 + 0])
                    let hi = UInt16(src[i * 2 + 1]) << 8
                    let v = Int16(bitPattern: lo | hi)
                    outBuf[i] = Float(v) / 32768.0
                    i += 1
                }
            }
        }

        return WAV16Mono(sampleRate: sr, samples: out)
    }
}

private struct WAVError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
