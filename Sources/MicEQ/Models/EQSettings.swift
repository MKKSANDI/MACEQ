import Foundation

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

private enum DecodeAnyKey {
    static func bool(_ c: KeyedDecodingContainer<AnyCodingKey>, _ keys: [String]) -> Bool? {
        for k in keys {
            if let v = (try? c.decodeIfPresent(Bool.self, forKey: AnyCodingKey(k))) ?? nil { return v }
        }
        return nil
    }

    static func double(_ c: KeyedDecodingContainer<AnyCodingKey>, _ keys: [String]) -> Double? {
        for k in keys {
            if let v = (try? c.decodeIfPresent(Double.self, forKey: AnyCodingKey(k))) ?? nil { return v }
        }
        return nil
    }

    static func uuid(_ c: KeyedDecodingContainer<AnyCodingKey>, _ keys: [String]) -> UUID? {
        for k in keys {
            if let v = (try? c.decodeIfPresent(UUID.self, forKey: AnyCodingKey(k))) ?? nil { return v }
        }
        return nil
    }

    static func string(_ c: KeyedDecodingContainer<AnyCodingKey>, _ keys: [String]) -> String? {
        for k in keys {
            if let v = (try? c.decodeIfPresent(String.self, forKey: AnyCodingKey(k))) ?? nil { return v }
        }
        return nil
    }

    static func value<T: Decodable>(_ c: KeyedDecodingContainer<AnyCodingKey>, _ keys: [String], as type: T.Type) -> T? {
        for k in keys {
            if let v = (try? c.decodeIfPresent(T.self, forKey: AnyCodingKey(k))) ?? nil { return v }
        }
        return nil
    }
}

enum EQBandType: String, CaseIterable, Identifiable, Codable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .bandPass: return "Band Pass"
        case .notch: return "Notch"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(String.self)) ?? ""
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()

        switch normalized {
        case "peaking", "peak", "bell":
            self = .peaking
        case "lowshelf", "low_shelf", "low-shelf":
            self = .lowShelf
        case "highshelf", "high_shelf", "high-shelf":
            self = .highShelf
        case "lowpass", "low_pass", "low-pass", "lp":
            self = .lowPass
        case "highpass", "high_pass", "high-pass", "hp":
            self = .highPass
        case "bandpass", "band_pass", "band-pass", "bp":
            self = .bandPass
        case "notch":
            self = .notch
        default:
            // Fall back to a safe, neutral filter shape.
            self = .peaking
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct EQBand: Identifiable, Hashable, Codable {
    let id: UUID
    var isEnabled: Bool
    var type: EQBandType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        type: EQBandType,
        frequencyHz: Double,
        gainDB: Double,
        q: Double
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }

    enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case type
        case frequencyHz
        case gainDB
        case q
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)

        id = DecodeAnyKey.uuid(c, ["id"]) ?? UUID()
        isEnabled = DecodeAnyKey.bool(c, ["isEnabled", "enabled"]) ?? true
        type = DecodeAnyKey.value(c, ["type", "bandType"], as: EQBandType.self) ?? .peaking
        frequencyHz = DecodeAnyKey.double(c, ["frequencyHz", "frequency", "hz"]) ?? 1_000
        gainDB = DecodeAnyKey.double(c, ["gainDB", "gainDb", "gain_db"]) ?? 0
        q = DecodeAnyKey.double(c, ["q", "Q"]) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(type, forKey: .type)
        try c.encode(frequencyHz, forKey: .frequencyHz)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(q, forKey: .q)
    }
}

struct EQSettings: Hashable, Codable {
    var preampDB: Double
    var outputGainDB: Double
    var bands: [EQBand]
    var isBypassed: Bool
    var noiseGate: NoiseGateSettings
    var compressor: CompressorSettings
    var deEsser: DeEsserSettings
    var voiceIsolation: VoiceIsolationSettings

    struct NoiseGateSettings: Hashable, Codable {
        var isEnabled: Bool
        /// Gate opens when the detected envelope exceeds this level (dBFS, typically negative).
        var thresholdDB: Double
        /// Additional dB below threshold required before the gate closes (prevents chatter).
        var hysteresisDB: Double
        /// How much attenuation is applied when closed (0 = no gating).
        var rangeDB: Double
        var attackMs: Double
        var holdMs: Double
        var releaseMs: Double

        init(
            isEnabled: Bool,
            thresholdDB: Double,
            hysteresisDB: Double,
            rangeDB: Double,
            attackMs: Double,
            holdMs: Double,
            releaseMs: Double
        ) {
            self.isEnabled = isEnabled
            self.thresholdDB = thresholdDB
            self.hysteresisDB = hysteresisDB
            self.rangeDB = rangeDB
            self.attackMs = attackMs
            self.holdMs = holdMs
            self.releaseMs = releaseMs
        }

        static let disabled = NoiseGateSettings(
            isEnabled: false,
            thresholdDB: -45,
            hysteresisDB: 4,
            rangeDB: 30,
            attackMs: 4,
            holdMs: 40,
            releaseMs: 120
        )

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            let d = NoiseGateSettings.disabled
            isEnabled = DecodeAnyKey.bool(c, ["isEnabled", "enabled"]) ?? d.isEnabled
            thresholdDB = DecodeAnyKey.double(c, ["thresholdDB", "thresholdDb", "threshold_db"]) ?? d.thresholdDB
            hysteresisDB = DecodeAnyKey.double(c, ["hysteresisDB", "hysteresisDb", "hysteresis_db"]) ?? d.hysteresisDB
            rangeDB = DecodeAnyKey.double(c, ["rangeDB", "rangeDb", "range_db"]) ?? d.rangeDB
            attackMs = DecodeAnyKey.double(c, ["attackMs"]) ?? d.attackMs
            holdMs = DecodeAnyKey.double(c, ["holdMs"]) ?? d.holdMs
            releaseMs = DecodeAnyKey.double(c, ["releaseMs"]) ?? d.releaseMs
        }
    }

    struct CompressorSettings: Hashable, Codable {
        var isEnabled: Bool
        var thresholdDB: Double
        var ratio: Double
        var kneeDB: Double
        var attackMs: Double
        var releaseMs: Double
        var makeupGainDB: Double

        init(
            isEnabled: Bool,
            thresholdDB: Double,
            ratio: Double,
            kneeDB: Double,
            attackMs: Double,
            releaseMs: Double,
            makeupGainDB: Double
        ) {
            self.isEnabled = isEnabled
            self.thresholdDB = thresholdDB
            self.ratio = ratio
            self.kneeDB = kneeDB
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.makeupGainDB = makeupGainDB
        }

        static let disabled = CompressorSettings(
            isEnabled: false,
            thresholdDB: -18,
            ratio: 3,
            kneeDB: 6,
            attackMs: 8,
            releaseMs: 80,
            makeupGainDB: 0
        )

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            let d = CompressorSettings.disabled
            isEnabled = DecodeAnyKey.bool(c, ["isEnabled", "enabled"]) ?? d.isEnabled
            thresholdDB = DecodeAnyKey.double(c, ["thresholdDB", "thresholdDb", "threshold_db"]) ?? d.thresholdDB
            ratio = DecodeAnyKey.double(c, ["ratio"]) ?? d.ratio
            kneeDB = DecodeAnyKey.double(c, ["kneeDB", "kneeDb", "knee_db"]) ?? d.kneeDB
            attackMs = DecodeAnyKey.double(c, ["attackMs"]) ?? d.attackMs
            releaseMs = DecodeAnyKey.double(c, ["releaseMs"]) ?? d.releaseMs
            makeupGainDB = DecodeAnyKey.double(c, ["makeupGainDB", "makeupGainDb", "makeup_gain_db"]) ?? d.makeupGainDB
        }
    }

    struct DeEsserSettings: Hashable, Codable {
        var isEnabled: Bool
        var frequencyHz: Double
        var q: Double
        var thresholdDB: Double
        var ratio: Double
        var attackMs: Double
        var releaseMs: Double
        /// Maximum attenuation applied to the sibilance band.
        var maxReductionDB: Double

        init(
            isEnabled: Bool,
            frequencyHz: Double,
            q: Double,
            thresholdDB: Double,
            ratio: Double,
            attackMs: Double,
            releaseMs: Double,
            maxReductionDB: Double
        ) {
            self.isEnabled = isEnabled
            self.frequencyHz = frequencyHz
            self.q = q
            self.thresholdDB = thresholdDB
            self.ratio = ratio
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.maxReductionDB = maxReductionDB
        }

        static let disabled = DeEsserSettings(
            isEnabled: false,
            frequencyHz: 7_500,
            q: 3.0,
            thresholdDB: -22,
            ratio: 6.0,
            attackMs: 2.0,
            releaseMs: 60.0,
            maxReductionDB: 8.0
        )

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            let d = DeEsserSettings.disabled
            isEnabled = DecodeAnyKey.bool(c, ["isEnabled", "enabled"]) ?? d.isEnabled
            frequencyHz = DecodeAnyKey.double(c, ["frequencyHz", "frequency"]) ?? d.frequencyHz
            q = DecodeAnyKey.double(c, ["q", "Q"]) ?? d.q
            thresholdDB = DecodeAnyKey.double(c, ["thresholdDB", "thresholdDb", "threshold_db"]) ?? d.thresholdDB
            ratio = DecodeAnyKey.double(c, ["ratio"]) ?? d.ratio
            attackMs = DecodeAnyKey.double(c, ["attackMs"]) ?? d.attackMs
            releaseMs = DecodeAnyKey.double(c, ["releaseMs"]) ?? d.releaseMs
            maxReductionDB = DecodeAnyKey.double(c, ["maxReductionDB", "maxReductionDb", "max_reduction_db"]) ?? d.maxReductionDB
        }
    }

    struct VoiceIsolationSettings: Hashable, Codable {
        var isEnabled: Bool
        /// Overall effect amount. 0 = off, 100 = strongest.
        var strength: Double
        /// Background/noise estimate in dBFS. Lower values are quieter rooms.
        var noiseFloorDB: Double
        /// Voice detector threshold in dBFS.
        var speechThresholdDB: Double
        /// Maximum attenuation applied to non-voice ambience.
        var reductionDB: Double
        /// Low edge of speech focus band.
        var focusLowHz: Double
        /// High edge of speech focus band.
        var focusHighHz: Double
        /// How fast isolation opens for speech.
        var attackMs: Double
        /// How smoothly isolation releases back into ambience reduction.
        var releaseMs: Double
        /// Extra presence added after isolation.
        var presenceBoostDB: Double

        init(
            isEnabled: Bool,
            strength: Double,
            noiseFloorDB: Double,
            speechThresholdDB: Double,
            reductionDB: Double,
            focusLowHz: Double,
            focusHighHz: Double,
            attackMs: Double,
            releaseMs: Double,
            presenceBoostDB: Double
        ) {
            self.isEnabled = isEnabled
            self.strength = strength
            self.noiseFloorDB = noiseFloorDB
            self.speechThresholdDB = speechThresholdDB
            self.reductionDB = reductionDB
            self.focusLowHz = focusLowHz
            self.focusHighHz = focusHighHz
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.presenceBoostDB = presenceBoostDB
        }

        static let disabled = VoiceIsolationSettings(
            isEnabled: false,
            strength: 45,
            noiseFloorDB: -58,
            speechThresholdDB: -42,
            reductionDB: 18,
            focusLowHz: 85,
            focusHighHz: 11_500,
            attackMs: 8,
            releaseMs: 260,
            presenceBoostDB: 1.5
        )

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            let d = VoiceIsolationSettings.disabled
            isEnabled = DecodeAnyKey.bool(c, ["isEnabled", "enabled"]) ?? d.isEnabled
            strength = DecodeAnyKey.double(c, ["strength", "amount", "mix"]) ?? d.strength
            noiseFloorDB = DecodeAnyKey.double(c, ["noiseFloorDB", "noiseFloorDb", "noise_floor_db"]) ?? d.noiseFloorDB
            speechThresholdDB = DecodeAnyKey.double(c, ["speechThresholdDB", "speechThresholdDb", "speech_threshold_db"]) ?? d.speechThresholdDB
            reductionDB = DecodeAnyKey.double(c, ["reductionDB", "reductionDb", "reduction_db", "maxReductionDB"]) ?? d.reductionDB
            focusLowHz = DecodeAnyKey.double(c, ["focusLowHz", "lowCutHz", "focus_low_hz"]) ?? d.focusLowHz
            focusHighHz = DecodeAnyKey.double(c, ["focusHighHz", "highCutHz", "focus_high_hz"]) ?? d.focusHighHz
            attackMs = DecodeAnyKey.double(c, ["attackMs"]) ?? d.attackMs
            releaseMs = DecodeAnyKey.double(c, ["releaseMs"]) ?? d.releaseMs
            presenceBoostDB = DecodeAnyKey.double(c, ["presenceBoostDB", "presenceBoostDb", "presence_boost_db"]) ?? d.presenceBoostDB
        }
    }

    enum CodingKeys: String, CodingKey {
        case preampDB
        case outputGainDB
        case bands
        case isBypassed
        case noiseGate
        case compressor
        case deEsser
        case voiceIsolation
    }

    init(
        preampDB: Double,
        outputGainDB: Double,
        bands: [EQBand],
        isBypassed: Bool,
        noiseGate: NoiseGateSettings = .disabled,
        compressor: CompressorSettings = .disabled,
        deEsser: DeEsserSettings = .disabled,
        voiceIsolation: VoiceIsolationSettings = .disabled
    ) {
        self.preampDB = preampDB
        self.outputGainDB = outputGainDB
        self.bands = bands
        self.isBypassed = isBypassed
        self.noiseGate = noiseGate
        self.compressor = compressor
        self.deEsser = deEsser
        self.voiceIsolation = voiceIsolation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        preampDB = DecodeAnyKey.double(c, ["preampDB", "preampDb", "preamp_db"]) ?? 0
        outputGainDB = DecodeAnyKey.double(c, ["outputGainDB", "outputGainDb", "output_gain_db"]) ?? 0
        bands = DecodeAnyKey.value(c, ["bands", "eqBands"], as: [EQBand].self) ?? EQSettings.default.bands
        isBypassed = DecodeAnyKey.bool(c, ["isBypassed", "bypassed"]) ?? false
        noiseGate = DecodeAnyKey.value(c, ["noiseGate", "gate"], as: NoiseGateSettings.self) ?? .disabled
        compressor = DecodeAnyKey.value(c, ["compressor"], as: CompressorSettings.self) ?? .disabled
        deEsser = DecodeAnyKey.value(c, ["deEsser", "deesser"], as: DeEsserSettings.self) ?? .disabled
        voiceIsolation = DecodeAnyKey.value(c, ["voiceIsolation", "voice_isolation", "isolation"], as: VoiceIsolationSettings.self) ?? .disabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preampDB, forKey: .preampDB)
        try c.encode(outputGainDB, forKey: .outputGainDB)
        try c.encode(bands, forKey: .bands)
        try c.encode(isBypassed, forKey: .isBypassed)
        try c.encode(noiseGate, forKey: .noiseGate)
        try c.encode(compressor, forKey: .compressor)
        try c.encode(deEsser, forKey: .deEsser)
        try c.encode(voiceIsolation, forKey: .voiceIsolation)
    }

    private static func defaultBands() -> [EQBand] {
        let anchors: [(Bool, EQBandType, Double, Double, Double)] = [
            (true, .highPass, 40, 0, 0.707),
            (false, .notch, 60, 0, 18),
            (false, .lowShelf, 100, 0, 0.9),
            (false, .peaking, 140, 0, 1.0),
            (false, .peaking, 220, 0, 1.0),
            (false, .peaking, 300, 0, 1.0),
            (false, .peaking, 350, 0, 1.0),
            (false, .peaking, 550, 0, 1.0),
            (false, .peaking, 800, 0, 1.0),
            (false, .peaking, 900, 0, 1.0),
            (false, .peaking, 1200, 0, 1.0),
            (false, .peaking, 1400, 0, 1.0),
            (false, .peaking, 1800, 0, 1.0),
            (false, .peaking, 2200, 0, 1.0),
            (false, .peaking, 2500, 0, 1.0),
            (false, .peaking, 3500, 0, 1.0),
            (false, .peaking, 4200, 0, 1.0),
            (false, .peaking, 5000, 0, 1.0),
            (false, .peaking, 7000, 0, 1.0),
            (false, .peaking, 9000, 0, 1.0),
            (false, .highShelf, 12_000, 0, 0.9),
            (false, .peaking, 14_000, 0, 1.0),
            (false, .peaking, 16_000, 0, 1.2),
            (false, .lowPass, 18_000, 0, 0.707),
        ]

        var bands = anchors.map {
            EQBand(isEnabled: $0.0, type: $0.1, frequencyHz: $0.2, gainDB: $0.3, q: $0.4)
        }

        let logMin = log10(20.0)
        let logMax = log10(20_000.0)
        while bands.count < 96 {
            let t = Double(bands.count - anchors.count) / Double(95 - anchors.count)
            let hz = pow(10.0, logMin + t * (logMax - logMin))
            bands.append(EQBand(isEnabled: false, type: .peaking, frequencyHz: hz, gainDB: 0, q: 1.0))
        }

        return bands
    }

    static let `default` = EQSettings(
        preampDB: 0,
        outputGainDB: 0,
        bands: defaultBands(),
        isBypassed: false,
        noiseGate: .disabled,
        compressor: .disabled,
        deEsser: .disabled,
        voiceIsolation: .disabled
    )
}
