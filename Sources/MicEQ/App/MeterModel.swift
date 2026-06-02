import Foundation

@MainActor
final class MeterModel: ObservableObject {
    @Published var inputLevelDB: Double = -80
    @Published var outputLevelDB: Double = -80
}

