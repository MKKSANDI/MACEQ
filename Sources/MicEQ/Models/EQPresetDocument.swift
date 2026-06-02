import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var macqPreset: UTType {
        UTType(exportedAs: "com.macq.preset", conformingTo: .json)
    }
}

struct EQPresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.macqPreset, .json] }
    static var writableContentTypes: [UTType] { [.macqPreset, .json] }

    var preset: EQPreset

    init(preset: EQPreset) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.preset = try decoder.decode(EQPreset.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        return FileWrapper(regularFileWithContents: data)
    }
}
